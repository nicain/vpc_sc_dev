#!/usr/bin/env bash

# User Settings:
export PROJECT_ID=vpc-sc-live-demo-nicholascain3
export REGION=us-central1
export PRINCIPAL=nicholascain@google.com

# Default Settings:
export BACKEND_PORT=443
export DOMAIN=webhook.internal
export GCE_INSTANCE=webhook
export INSTANCE_GROUP=webhook
export NETWORK=webhook-net
export SUBNET=webhook-subnet
export SETUP_SA_NAME=sa-setup
export SETUP_SA_KEY_DIR=./.secret
export NGINX_SSL_DIR=./nginx_ssl
export WEBHOOK_NAME=custom-telco-webhook
export WEBHOOK_ENTRYPOINT=cxPrebuiltAgentsTelecom
export WEBHOOK_RUNTIME=python39
export AGENT_SOURCE_URI=gs://gassets-api-ai/prebuilt_agents/cx-prebuilt-agents/exported_agent_Telecommunications.blob

# Parameters:
export PROJECT_NUMBER=$(gcloud projects list --filter=${PROJECT_ID?} --format="value(PROJECT_NUMBER)")
export ZONE=${REGION?}-b
export SETUP_SA_KEY_FILE=${SETUP_SA_KEY_DIR?}/key.json
export SA_IAM_ACCOUNT=${SETUP_SA_NAME?}@${PROJECT_ID?}.iam.gserviceaccount.com
export NGINX_SSL_KEY=${NGINX_SSL_DIR?}/server.key
export NGINX_CSR_KEY=${NGINX_SSL_DIR?}/server.csr
export NGINX_CRT_KEY=${NGINX_SSL_DIR?}/server.crt
export NGINX_DER_KEY=${NGINX_SSL_DIR?}/server.der


# Initialize:
gcloud auth login -q ${PRINCIPAL?} --no-launch-browser
gcloud config set project ${PROJECT_ID?}

# Enable APIs:
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  dialogflow.googleapis.com \
  servicedirectory.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  cloudfunctions.googleapis.com

# Configure service identity/service accounts and roles
gcloud beta services identity create --service=dialogflow.googleapis.com
gcloud iam service-accounts create ${SETUP_SA_NAME?} \
  --description="Service account for project setup" \
  --display-name=${SETUP_SA_NAME?}
mkdir -p ${SETUP_SA_KEY_DIR?}
gcloud iam service-accounts keys create ${SETUP_SA_KEY_FILE?} --iam-account=${SA_IAM_ACCOUNT?}
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:${SA_IAM_ACCOUNT?} --role=roles/storage.admin
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:${SA_IAM_ACCOUNT?} --role=roles/compute.admin
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:${SA_IAM_ACCOUNT?} --role=roles/iam.serviceAccountUser
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:${SA_IAM_ACCOUNT?} --role=roles/cloudfunctions.developer
gcloud auth activate-service-account --key-file=${SETUP_SA_KEY_FILE?}
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:service-${PROJECT_NUMBER?}@gcp-sa-dialogflow.iam.gserviceaccount.com --role=roles/servicedirectory.viewer
gcloud projects add-iam-policy-binding ${PROJECT_ID?} --member=serviceAccount:service-${PROJECT_NUMBER?}@gcp-sa-dialogflow.iam.gserviceaccount.com --role=roles/servicedirectory.pscAuthorizedService

# Create TLS keys:
mkdir -p ${NGINX_SSL_DIR?}
openssl genrsa -out ${NGINX_SSL_KEY?} 2048
openssl req -nodes -new -sha256 -key ${NGINX_SSL_KEY?} -subj "/CN=${DOMAIN}" -out ${NGINX_CSR_KEY?}
openssl x509 -req -days 3650 -in ${NGINX_CSR_KEY?} -signkey ${NGINX_SSL_KEY?} -out ${NGINX_CRT_KEY?} -extfile <(printf "\nsubjectAltName='DNS:${DOMAIN}")
openssl x509 -in ${NGINX_CRT_KEY?} -out ${NGINX_DER_KEY?} -outform DER
gsutil mb gs://${PROJECT_ID?}
gsutil cp -r ${NGINX_SSL_DIR?} gs://${PROJECT_ID?}
rm -rf ${NGINX_SSL_DIR?}

# Configure Network:
gcloud compute networks create ${NETWORK?} --project=${PROJECT_ID?} --subnet-mode=custom
gcloud compute networks subnets create ${SUBNET?} \
  --project=${PROJECT_ID?} \
  --network=${NETWORK?} \
  --region=${REGION?} \
  --enable-private-ip-google-access \
  --range=10.10.20.0/24
gcloud compute firewall-rules create allow \
  --network ${NETWORK?} \
  --allow tcp:22,tcp:3389,icmp

# Configure GCE Instance:
gcloud compute instances create ${GCE_INSTANCE?} \
  --project=${PROJECT_ID?} \
  --zone=${ZONE?} \
  --machine-type=e2-medium \
  --maintenance-policy=MIGRATE \
  --tags=lb-backend \
--create-disk=auto-delete=yes,boot=yes,device-name=instance-1,image=projects/debian-cloud/global/images/debian-10-buster-v20220519,mode=rw,size=10,type=projects/${PROJECT_ID?}/zones/${ZONE?}/diskTypes/pd-balanced \
  --no-shielded-secure-boot \
  --shielded-vtpm \
  --shielded-integrity-monitoring \
  --reservation-affinity=any \
  --metadata=startup-script='#! /bin/bash
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    nginx \
    git'
gcloud compute instance-groups unmanaged create webhook --zone=${ZONE?}
gcloud compute instance-groups unmanaged add-instances webhook --zone=${ZONE?} --instances=${GCE_INSTANCE?}

# Deploy the webhook:
gcloud functions deploy ${WEBHOOK_NAME?} --entry-point ${WEBHOOK_ENTRYPOINT?} --runtime ${WEBHOOK_RUNTIME?} --trigger-http --source=./webhook
WEBHOOK_TRIGGER_URI=$(gcloud functions describe ${WEBHOOK_NAME?} --format json | jq -r .httpsTrigger.url)

# Test the webhook:
curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  -H "Content-Type:application/json" \
  --data \
  '{
    "fulfillmentInfo":{
      "tag":"validatePhoneLine"
    },
    "sessionInfo":{
      "parameters":{
        "phone_number":"123456"
      }
    }
  }' \
  https://us-central1-vpc-sc-live-demo-nicholascain3.cloudfunctions.net/custom-telco-webhook

# Deploy the Dialogflow CX Agent:
curl -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -d \
  '{
    "displayName": "Telecommunications",
    "defaultLanguageCode": "en",
    "timeZone": "America/Chicago"
  }' \
  "https://${REGION?}-dialogflow.googleapis.com/v3/projects/${PROJECT_ID?}/locations/${REGION?}/agents" > agents.json
export AGENT_NAME=$(cat agents.json| jq -r '.name')
curl -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -d \
  "{
    \"agentUri\": \"${AGENT_SOURCE_URI}\"
  }" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${AGENT_NAME?}:restore"


# Update the Dialogflow agent to query the webhook URI:
curl -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${AGENT_NAME?}/webhooks" > webhooks.json
export DF_WEBHOOK_NAME=$(cat webhooks.json| jq -r '.webhooks[0].name')
curl -X PATCH -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -d \
  "{
    \"displayName\": \"cxPrebuiltAgentsTelecom\",
    \"genericWebService\": {\"uri\": \"${WEBHOOK_TRIGGER_URI?}\"}
  }" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${DF_WEBHOOK_NAME?}"

# Test the Dialogflow agent against the webhook URI:
curl -X GET -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${AGENT_NAME?}/flows" > flows.json
export CRUISE_PLAN_FLOW=$(cat flows.json | jq -r '.flows | map(select(.displayName== "Cruise Plan"))[0].name')
curl -X GET -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${CRUISE_PLAN_FLOW?}/pages" > cruise_plan_flow_pages.json
export CUSTOMER_LINE_PAGE=$(cat cruise_plan_flow_pages.json | jq -r '.pages | map(select(.displayName== "Collect Customer Line"))[0].name')
curl -s -X POST -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
  -H "Content-Type:application/json" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -d \
  "{
    \"queryInput\": {\"languageCode\": \"en\", \"text\": {\"text\": \"123456\"}},
    \"queryParams\": {\"currentPage\": \"${CUSTOMER_LINE_PAGE?}\"}
  }" \
  "https://${REGION?}-dialogflow.googleapis.com/v3/${AGENT_NAME?}/sessions/123456:detectIntent" > response.json
cat response.json | jq -r '.queryResult.responseMessages[0].text.text[0]'

