#!/bin/bash
set -a

# get-credentials of k8s cluster
function _gke_get_credentials () {
	count=0
	# retry loop with incremental wait time for fetching GKE credentials to run kubectl commands
	while true;
	do
		test $count -gt $count_limit && {
			echo "(ERROR) Scaling-Cron unable to retrive credentials for GKE cluster = ${K8S_CLUSTER_NAME}"
			_send_alert ${ALERT_TYPE} '(ERROR) Scaling-Cron unable to retrive credentials for GKE cluster = '${K8S_CLUSTER_NAME}''
			exit ;}
        	gcloud auth activate-service-account --key-file /var/run/secret/cloud.google.com/gke-service-account.json && \
		gcloud config set project $(grep project_id /var/run/secret/cloud.google.com/gke-service-account.json | cut -d'"' -f4) && \
		gcloud container clusters get-credentials ${K8S_CLUSTER_NAME} --zone ${K8S_CLUSTER_ZONE} && \
		break
		count=$(expr $count + 1)
		sleep $(expr $count \* 30)s
	done
}

function _remove_lock_file () {
    test -f ${LOCKFILE} && rm -f ${LOCKFILE}
}

# run kubectl scale command
# usage: _kubectl_scale ${NEW_DESIRED_REPLICAS}
function _kubectl_scale () {
    kubectl scale --namespace="${K8S_NAMESPACE:=default}" --replicas=${1} deployment/${K8S_DEPLOYMENT}
	return $?
}

# defines success critrion/steps for kubectl scale command
# usage: _kubectl_scale_success ${NEW_DESIRED_REPLICAS}
function _kubectl_scale_success () {
	echo "${1}" > ${TEMP_DIR}/last_scaling_count
    echo "(INFO) \"kubectl scale  --namespace=${K8S_NAMESPACE:=default} --replicas=${1} deployment/${K8S_DEPLOYMENT}\" [success]."
    _remove_lock_file
}

# function to send alert to slack or email(via sendgrid)
function _send_alert () {
	while test $# -gt 0;
	do
		case $1 in
			slack)
				shift
				ALERT_MSG="${@}"
				if [[ ! -z "${SLACK_WEBHOOK_URL}" ]]; then
					# send slack alert using curl call
					curl -s --request POST \
					  --data 'payload={"text":"*[K8S Scaling Cron]*","attachments":[{"text":"'"${ALERT_MSG}"'","color":"#FF0000"}]}' \
					  --url ${SLACK_WEBHOOK_URL} >/dev/null
					if [[ $? -ne 0 ]]; then
						echo "(ERROR) curl call to post alert on slack webhook url [failed]."
					fi
				else
					echo "(ERROR) \"SLACK_WEBHOOK_URL\" not set, thus skipping curl call to post alert on Slack."
				fi
				break
			;;
			email)
				shift
				ALERT_MSG="<p>${@}</p>"
				if [[ ! -z "${SENDGRID_API_KEY}" ]]; then
					if [[ -z ${EMAIL_TO} ]]; then EMAIL_TO="firefighter@sigtuple.com"; fi
					if [[ -z ${FROM_EMAIL} ]]; then FROM_EMAIL="no-reply@sigtuple.com"; fi
					if [[ -z ${EMAIL_SUBJECT} ]]; then EMAIL_SUBJECT="(ALERT) form [K8S Scaling Cron]"; fi
					# generating JSON data
					mailDATA='{"personalizations": [{"to": [{"email": "'${EMAIL_TO}'"}]}],"from": {"email": "'${FROM_EMAIL}'","name": "'${FROM_EMAIL_NAME}'"},"subject": "'${EMAIL_SUBJECT}'","content": [{"type": "text/html", "value": "'${ALERT_MSG}'"}]}'
					# send email alert using curl call
					curl -s --request POST \
					  --url https://api.sendgrid.com/v3/mail/send \
					  --header 'Authorization: Bearer '${SENDGRID_API_KEY} \
					  --header 'Content-Type: application/json' \
					  --data "'${mailDATA}'" >/dev/null
					if [[ $? -ne 0 ]]; then
                                                echo "(ERROR) curl call to post email alert through Sendgrid [failed]."
                                        fi
				else
					echo "(ERROR) \"SENDGRID_API_KEY\" not set, thus skipping curl call to post email alert through Sendgrid."
				fi
				break
			;;
			null|none)
				# do not send any alert
				true
			;;
		esac
	done
}

## Start ##

# file holds timestamp, so that number of attempts(iterations of while loop) for scaling can be controlled in specific time range
LOCKFILE="/tmp/k8s-cron.lock"
count_limit=10

# fetch GKE credentials to run kubectl commands for scaling deployments
_gke_get_credentials

TEMP_DIR="/tmp/k8s-$(id -u)"
# create temp dir if not exists
test -d ${TEMP_DIR} || mkdir ${TEMP_DIR}

while true
do # start of while loop

	# sleep before running next iteration
	sleep ${SLEEP_SECONDS:=15}s

	# create lock file and store timestamp in it
	if ! test -f ${LOCKFILE}; then
		echo $(date +%s) > ${LOCKFILE}
	else
		# force remove if lockfile if it is older than 60 seconds
		if [[ $(( $(date +%s) - $(cat ${LOCKFILE}) )) -gt 60 ]]; then
			rm -f ${LOCKFILE}
		fi
		# skip this iteration and continue to next
		continue
	fi

	count=0
	# test redis server connectivity with 3 second timeout
	until test "$(timeout 3 redis-cli --raw -h ${REDIS_HOST} -p ${REDIS_PORT:=6379} ping | tr '[:upper:]' '[:lower:]')" = "pong"
	do
		test $count -gt $count_limit && {
			echo "(ERROR) unable to reach redis server = ${REDIS_HOST} on port = ${REDIS_PORT}"
			_send_alert ${ALERT_TYPE} '(ERROR) unable to reach redis server = '${REDIS_HOST}' on port = '${REDIS_PORT}'. Ref: '${K8S_NAMESPACE}'/'${K8S_DEPLOYMENT}''
			rm -f ${LOCKFILE}
			exit ;}
		count=$(expr $count + 1)
		# retry loop with incremental wait time
		sleep $(expr $count \* 30)s
	done # end of until loop
	
	if test $(redis-cli --raw -h ${REDIS_HOST} -p ${REDIS_PORT:=6379} -n ${REDIS_DB:=0} EXISTS COUNT_FOR_${PRODUCT}_${MODEL}_${VERSION}) -eq 0; then
		# if key does not exist then set it to 0(zero)
		redis-cli --raw -h ${REDIS_HOST} -p ${REDIS_PORT:=6379} -n ${REDIS_DB:=0} SET "COUNT_FOR_${PRODUCT}_${MODEL}_${VERSION}" 0
	fi

	# get new desired replica count from redis
	NEW_DESIRED_REPLICAS=$(redis-cli --raw -h ${REDIS_HOST} -p ${REDIS_PORT:=6379} -n ${REDIS_DB:=0} GET COUNT_FOR_${PRODUCT}_${MODEL}_${VERSION})
	test -z ${NEW_DESIRED_REPLICAS} && {
		echo "(ERROR) NEW_DESIRED_REPLICAS value is empty, thus exiting process to let K8S recreate it. Check for error's in connectivity to redis-server = ${REDIS_HOST}."
		exit ;}

	# create last_scalin_count file if not already
	test -f ${TEMP_DIR}/last_scaling_count || echo '1' > ${TEMP_DIR}/last_scaling_count

	if test ${NEW_DESIRED_REPLICAS} -eq $(cat ${TEMP_DIR}/last_scaling_count); then
		# skip further processing if new desired replica count is not changed
        _remove_lock_file
		continue
	elif test ${NEW_DESIRED_REPLICAS} -gt ${MAX_REPLICAS}; then
		# do not scale beyond defined max limit
		echo "(INFO) New Desired Replica count (${NEW_DESIRED_REPLICAS}) is greater than Allowed Max Replicas (${MAX_REPLICAS}), thus skipping scaling operation."
        _remove_lock_file
        continue
	else
		# scale replicas to new desired replica count
		_kubectl_scale ${NEW_DESIRED_REPLICAS}
		if test $? -eq 0; then
				_kubectl_scale_success ${NEW_DESIRED_REPLICAS}
		else
        	echo "(ERROR) \"kubectl scale --namespace=${K8S_NAMESPACE:=default} --replicas=${NEW_DESIRED_REPLICAS} deployment/${K8S_DEPLOYMENT}\" [failed]."
        	_send_alert ${ALERT_TYPE} '(ERROR) `kubectl scale --namespace='${K8S_NAMESPACE:=default}' --replicas='${NEW_DESIRED_REPLICAS}' deployment/'${K8S_DEPLOYMENT}'` command returned unsuccessful status code.'
			# at first attempt, try to check and handle error if cause by migration due to gcp preemptible nodes
			kubectl get --namespace="${K8S_NAMESPACE:=default}" deployment ${K8S_DEPLOYMENT} >/dev/null
			if test $? -ne 0; then
				echo "(ERROR) \"kubectl get --namespace=${K8S_NAMESPACE:=default} deployment ${K8S_DEPLOYMENT}\" [failed]."
				_send_alert ${ALERT_TYPE} '(ERROR) `kubectl get --namespace='${K8S_NAMESPACE:=default}' deployment '${K8S_DEPLOYMENT}'` command returned unsuccessful status code.'	
				_gke_get_credentials
			fi
			_remove_lock_file
		fi
	fi

done # end of while loop
