#!/bin/sh

##############################################################################################################################
# Script stores API-Keys in the Gloo Portal Redis storage.
#
# author: duncan.doyle@solo.io
###############################################################################################################################

############################################### Variables ###############################################

# ExtAuth config-id. Needs to match the APIKey ExtAuthPolicy configured on the APIProduct routetables.
export DEFAULT_EXT_AUTH_CONFIG_ID="gloo-mesh.api-key-auth-default-gg-demo-single-ext-auth-service"

##########################################################################################################

############################################ Argument parsing ############################################

function usage {
      echo "Usage: store-portal-api-key.sh [args...]"
      echo "where args include:"
      echo "	-u		Username under which to store the API-Key."
      echo "	-p		Usage-Plan for this key."
      echo "	-n		Name of the API-Key."
      echo "	-k		The API-Key to store."
      echo "	-e 		Ext Auth configuration to which to link the API Key. (optional)"
}

#Parse the params
while getopts ":u:p:n:k:e:h" opt; do
  case $opt in
    u)
      USERNAME=$OPTARG
      ;;
    p)
      USAGE_PLAN=$OPTARG 
      ;;
    n)
      API_KEY_NAME=$OPTARG
      ;;
    k)
      API_KEY=$OPTARG
      ;;
    e) 
      EXT_AUTH_CONFIG_ID=$OPTARG
      ;;
    h)
      usage
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

PARAMS_NOT_OK=false

#Check params
if [ -z "$USERNAME" ] 
then
	echo "No username specified"
	PARAMS_NOT_OK=true
fi

if [ -z "$USAGE_PLAN" ]
then
	echo "No usage-plan specified!"
	PARAMS_NOT_OK=true
fi

if [ -z "$API_KEY_NAME" ]
then
	echo "No api-key name specified!"
	PARAMS_NOT_OK=true
fi

if [ -z "$API_KEY" ]
then
	echo "No api-key specified!"
	PARAMS_NOT_OK=true
fi
if [ -z "EXT_AUTH_CONFIG_ID" ]
then
	EXT_AUTH_CONFIG_ID=$DEFAULT_EXT_AUTH_CONFIG_ID
fi

if $PARAMS_NOT_OK
then
	usage
	exit 1
fi

##########################################################################################################

# Retrieve the Portal storage key from K8S secret
export PORTAL_STORAGE_SECRET_KEY=$(kubectl -n gloo-mesh get secret portal-storage-secret-key -o jsonpath='{.data.key}')
export PORTAL_STORAGE_SECRET_KEY_NONBASE64=$(printf $PORTAL_STORAGE_SECRET_KEY | base64 -d)

# Calculate the HMAC using the passed in key and the Portal storage secret.
export HMAC=$(printf $API_KEY | openssl sha256 -hmac $PORTAL_STORAGE_SECRET_KEY_NONBASE64 | cut -c16- | xxd -r -p | base64)

export UUID=$(uuidgen)
export TIMESTAMP=$(date +%s)

export MSG=$(cat <<EOM
{
  "api_key": "$HMAC",
  "labels": [
    "$USERNAME"
  ],
  "metadata": {
    "config_id": "$EXT_AUTH_CONFIG_ID",
    "created-ts-unix": "$TIMESTAMP", 
    "name": "$API_KEY_NAME", 
    "usagePlan": "$USAGE_PLAN",
    "username": "$USERNAME"
  },
  "uuid": "$UUID"
}
EOM
)

printf "\nStoring API-Key with name \"$API_KEY_NAME\" and usage-plan \"$USAGE_PLAN\" for user \"$USERNAME\" in Redis.\n"

# First write the Hash and UUID.
kubectl -n gloo-mesh exec deploy/redis -- redis-cli SET $UUID $HMAC

# Now write the API-Key entry.
kubectl -n gloo-mesh exec deploy/redis -- redis-cli SET $HMAC "$MSG"

# And add the entry to the user's api-key set.
kubectl -n gloo-mesh exec deploy/redis -- redis-cli SADD $USERNAME $HMAC

printf "\nOperation completed.\n"