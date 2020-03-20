FROM gcr.io/google.com/cloudsdktool/cloud-sdk:slim
RUN apt update \
&& apt install kubectl redis-tools curl -y
COPY ./scaling-cron.sh .
CMD ["/bin/bash", "scaling-cron.sh"]
