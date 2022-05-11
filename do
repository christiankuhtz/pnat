#!/bin/zsh
#set -x 

# "known good defaults", can be modified in CONFIG file

PROJ=pnat
LOCATION=westcentralus
declare -A PREFIX
declare -A PREFIXLEN
declare -A PIPADDR
declare -A PORT
declare -A SUBNETSUFFIX
declare -A PRIVIPADDR
# only /24 supported
PREFIX[source]=100.64.0
PREFIX[destination]=100.64.1
PREFIXLEN[source]=/24
PREFIXLEN[destination]=/24
MYIPADDR=`dig +short myip.opendns.com @resolver1.opendns.com`/32
echo "my IP address is ${MYIPADDR}"
PORT[ssh]=22
PORT[wireguard]=51820
SUBNETSUFFIX[gw]=16
SUBNETSUFFIX[vm]=17
CONFIG=./config
ACCELNET="--accelerated-networking"
VMSKU=Standard_D2s_v5
LOG=${PROJ}.log


# Check if Azure CLI exists

az 2>%1 >/dev/null
if [ $? -eq 0 ]
then
  echo "Azure CLI exists"
else
  echo "Azure CLI required. Install or check installation."
fi

# check if CONFIG file exists and explain which parameters were set

if [[ -a ${CONFIG} ]]
then
  if [[ -r ${CONFIG} ]]
  then 
    source ${CONFIG}
  else
    echo "config file (${CONFIG}) unreadable. aborting." && exit 1
  fi
else
  echo "config file (${CONFIG}) missing. aborting." && exit 1
fi

# Advise on creds

if [[ -z ${ADMINUSER} ]]
then
  echo "ADMINUSER parameter in file ${CONFIG} missing. aborting." && exit 1
fi
if [[ -z ${ADMINPASS} ]]
then
  echo "ADMINPASS parameter in file ${CONFIG} missing (must match Azure password rules). aborting." && exit 1
fi
echo "credentials found in ${CONFIG}."

# Advise on location

if [[ -z ${LOCATION} ]]
then
  echo -n "LOCATION not found in ${CONFIG}. Using default "
else
  echo -n "LOCATION found in ${CONFIG}. Using "
fi
echo "region ${LOCATION}."

# Advise on log file

if [[ -a ${LOG} ]]
then
  echo "${LOG} exists, will be overwritten."
else
  echo "${LOG} will be created."
fi

# Check if yaml configs exist

for COMPONENT in source destination; do
  for TYPE in vm gw; do
    if [[ -r ${COMPONENT}-${TYPE}-init.yaml ]]
    then
      echo "found readable ${COMPONENT}-${TYPE}-init.yaml."
    else
      echo "cloud-init YAML for ${COMPONENT}-${TYPE} doesn't exist. exiting." && exit 1
    fi
  done
done

# Check if resource group exists, kill if it does

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  echo -n "rg ${RG} does"
  if [ "`az group exists --name ${RG}`" = "true" ];
  then
    echo -n " exist.. deleting.."
    az group delete \
    --resource-group ${RG} \
    --yes \
    --only-show-errors \
    >${LOG} 2>&1 || exit 1
  else
    echo -n "n't exist.."
  fi

# Create clean resource group

  echo -n " creating.."
  az group create \
    --name ${RG} \
    --location ${LOCATION} \
    >>${LOG} 2>&1 || exit 1
  echo " done."

# Create vnets

  echo -n "deploying ${COMPONENT}-vnet.."
  az network vnet create \
    --resource-group ${RG} \
    --name ${COMPONENT}-vnet \
    --address-prefix ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    --subnet-name ${COMPONENT}-subnet \
    --subnet-prefixes ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    >>${LOG} 2>&1 || exit 1
  echo " done."

# Create public IPs and retrieve the addr

  for TYPE in vm gw; do
    echo -n "deploying ${COMPONENT}-${TYPE}-pip.."
      az network public-ip create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE}-pip \
      --sku Standard \
      >>${LOG} 2>&1 || exit 1
    echo " done."

    echo -n "retrieve IP address of ${COMPONENT}-${TYPE}-pip.."
    PIPADDR[${COMPONENT}-${TYPE}]=`az network public-ip show \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE}-pip \
      --query "ipAddress" \
      | sed 's/\"//g'`/32
    echo " done. ${PIPADDR[${COMPONENT}-${TYPE}]}"

# Create NSG and NSG rule

    echo -n "deploying ${COMPONENT}-${TYPE}-nsg.."
    az network nsg create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE}-nsg \
      >>${LOG} 2>&1 || exit 1
    echo " done."

    echo -n "creating ${COMPONENT}-${TYPE}-nsg-rule.."
    az network nsg rule create \
      --resource-group ${RG} \
      --nsg-name ${COMPONENT}-${TYPE}-nsg \
      --name ssh-myip \
      --description "Not so wide open ssh" \
      --priority 100 \
      --destination-port-ranges ${PORT[ssh]} \
      --source-address-prefixes ${MYIPADDR} \
      --direction Inbound \
      --protocol Tcp \
      >>${LOG} 2>&1 || exit 1
    echo " done. (${MYIPADDR}->${PIPADDR[${COMPONENT}-${TYPE}]}:${PORT[ssh]})"

# Create NIC

    echo -n "deploying ${COMPONENT}-${TYPE}-nic.."
    PRIVIPADDR[${COMPONENT}-${TYPE}]=${PREFIX[${COMPONENT}]}.${SUBNETSUFFIX[${TYPE}]}
    az network nic create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE}-nic \
      --vnet-name ${COMPONENT}-vnet \
      --subnet ${COMPONENT}-subnet \
      --ip-forwarding \
      --network-security-group ${COMPONENT}-${TYPE}-nsg \
      --public-ip-address ${COMPONENT}-${TYPE}-pip \
      --private-ip-address ${PRIVIPADDR[${COMPONENT}-${TYPE}]} \
      ${ACCELNET} \
      >>${LOG} 2>&1 || exit 1
    echo " done. (${PRIVIPADDR[${COMPONENT}-$TYPE]})"
  done
done

# Make sure we know who the opposite end is

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  if [[ ${COMPONENT} == "source" ]]
  then
    OTHER="destination"
  else
    OTHER="source"
  fi

# Allow wireguard between gateways

  echo -n "creating ${COMPONENT}-gw-nsg-rule.."
  az network nsg rule create \
    --resource-group ${RG} \
    --nsg-name ${COMPONENT}-gw-nsg \
    --name wireguard-hop \
    --description "${PIPADDR[${OTHER}-gw]}->${PIPADDR[${COMPONENT}-gw]}:${PORT[wireguard]}" \
    --priority 103 \
    --source-address-prefixes ${PIPADDR[${OTHER}-gw]} \
    --destination-port-ranges ${PORT[wireguard]} \
    --direction Inbound \
    --protocol Udp \
    >>${LOG} 2>&1 || exit 1
  echo " done. (${PIPADDR[${OTHER}-gw]}->${PIPADDR[${COMPONENT}-gw]}:${PORT[wireguard]})"
done

# Create our VMs

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  for TYPE in vm gw; do
    echo -n "creating ${COMPONENT} ${TYPE} VM.."
    az vm create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE} \
      --image UbuntuLTS \
      --nics ${COMPONENT}-${TYPE}-nic \
      --size ${VMSKU} \
      --admin-username "${ADMINUSER}" \
      --admin-password "${ADMINPASS}" \
      --custom-data ${COMPONENT}-${TYPE}-init.yaml \
      >>${LOG} 2>&1 || exit 1
    echo " done."
  done
done

# Show what was configured

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  for TYPE in vm gw; do
    echo "${COMPONENT}-${TYPE}: ${PIPADDR[${COMPONENT}-${TYPE}]} | ${PRIVIPADDR[${COMPONENT}-${TYPE}]}"
  done
done

# Everything _should_ be done by the time we get here.

echo "done."
