# K8S Custom Autoscaler

This implementation autoscales (in/out) the K8S deployment based on a scaling number read from Redis.


## Why have I written this autoscaler?

> In this use case - an incoming request consisting image passed to the set of containers, each containing ML model served by TF Serving. These stateless containers are hosted on Kubernetes (GKE). During POC's the estimation for optimal resource (cpu/mem) 'request' and 'limit' required to process a single image by a model at a time was analyzed and used in the k8S deployment manifest file.

### To serve multiple images at a time, require autoscaling a K8S deployment and we considered the following option before writing custom auto-scaler. 

* Implemented HorizontalPodAutoscaler (HPA) with CPU and Mem metrics. Delayed & nonlinear pod autoscaling caused multiple requests to land on same containers at a time causing OutOfMemory errors, increased failure rates with increase in number of requests, thus delaying the result affecting overall Turn Around Time (TAT) for analysis.
* Implemented HPA with external metric using requests made to Ingress. Scaling of deployment was linear but delayed until the metrics are available to the HPA controller via metric API is too late to spawn. This is causing the same issues as above but at a reduced frequency for successively incremental request count. Pre-warming could be a solution, but deciding a time to conduct pre-warming is again trivial in this case. 

#### Custom Autoscaler

* As pre-warming is trivial but what can be predicted at the very start of the process pipeline is - how many images are incoming? and linearly have to decide the scaling number, which can be stored in redis a key. The value of this redis key is utilized by Autoscaler to scale (in/out) the corresponding deployment.

> The major challenge in this implementation is controlling this behaviour of scaling-in. Because the scaling number can be decreased based on the number of analyses done. Behind the scenes autoscaler utilizes the `kubectl scale` command to pass that number as argument to `--replicas`, telling ReplicaSet controller to bring the deployment count to that number. Here, I am not aware of any way to tell what pods to terminate. But on contrary very rarely I've faced the issue of a pod getting terminated while still processing a request.

> Therefore, to handle any failures, we have implemented retries with increment time gap.    

* **Steps to provision Autoscaler on GCP:**

Here variables like Product, Model, Version are defined in the files, signifying various combinations possible & how important it is to use automation and templating to maintain records in easiest way possible.

> I have not described only a small segment of the entire pipeline. Assume that some service is populating the Redis for scaling number and another service is passing requests to spawned (TF Serving) containers via route Ingress -> ClusterIP service -> Deployment > Pods.   

  - build scaling cron docker image and push it to gcr.io 
    ```
    export gcp_project_id=
    docker build -t gcr.io/${gcp_project_id}/scaling_cron:latest -f Dockerfile .
    docker push gcr.io/${gcp_project_id}/scaling_cron
    ```
  - create GKE cluster, create GCP IAM service account with GKE admin access and create k8s secret
    `kubectl create secret generic gcs-admin-access --from-file /tmp/gcs-service-account.json`
  - generate k8s deployment manifest file using ansible-playbook. Do pass values to extra-vars.
    `ansible-playbook ansible.yaml --extra-vars 'k8s_cluster_name= k8s_cluster_zone= redis_fqdn='`
  - apply deployment manifest using `kubectl` to GKE cluster
    `kubectl apply -f <deployment-file.yaml>`


## What's next?

* Recently, I've come across a K8S resource pattern called (Jobs)[https://kubernetes.io/docs/concepts/workloads/controllers/jobs-run-to-completion/]. Thinking of refactoring the entire implementation with:
  - A Deployment that dispenses a Job.
  - A Job that performs model analysis on image batches assigned in a reliable way with retries(backoffLimit). 


## What is the key take away?

* What we explored & their trade-offs.
* Have a look at the [scaling-cron.sh](scaling-cron.sh) file. I have reached to this state are some iterations necessary to host it statelessly and in an auto-recoverable manner on preemptible nodes, which auto-destruct after 24 hours. 