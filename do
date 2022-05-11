#!/bin/zsh
#set -x 
PROJ=pnat
#LOCATION=westus2
LOCATION=westus3
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
CREDS=./creds
ACCELNET="--accelerated-networking"
VMSKU=Standard_D2s_v5
LOG=${PROJ}.log

if [[ -a ${LOG} ]]
then
  echo "${LOG} exists, will be overwritten."
else
  echo "${LOG} will be created."
fi

if [[ -a ${CREDS} ]]
then
  if [[ -r ${CREDS} ]]
  then 
    source ${CREDS}
  else
    echo "credentials file (${CREDS}) unreadable. aborting." && exit 1
  fi
else
  echo "credentials file (${CREDS}) missing. aborting." && exit 1
fi


if [[ -z ${ADMINUSER} ]]
then
  echo "ADMINUSER parameter in file ${CREDS} missing. aborting." && exit 1
fi
if [[ -z ${ADMINPASS} ]]
then
  echo "ADMINPASS parameter in file ${CREDS} missing (must match Azure password rules). aborting." && exit 1
fi
echo "credentials found in ${CREDS}."

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

  echo -n " creating.."
  az group create \
    --name ${RG} \
    --location ${LOCATION} \
    >>${LOG} 2>&1 || exit 1
  echo " done."

  echo -n "deploying ${COMPONENT}-vnet.."
  az network vnet create \
    --resource-group ${RG} \
    --name ${COMPONENT}-vnet \
    --address-prefix ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    --subnet-name ${COMPONENT}-subnet \
    --subnet-prefixes ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    >>${LOG} 2>&1 || exit 1
  echo " done."

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

    echo -n "deploying ${COMPONENT}-${TYPE}-nsg.."
    az network nsg create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE}-nsg \
      >>${LOG} 2>&1 || exit 1
    echo " done."

    # echo -n "creating ${COMPONENT}-${TYPE}-nsg-rule.."
    # az network nsg rule create \
    #   --resource-group ${RG} \
    #   --nsg-name ${COMPONENT}-${TYPE}-nsg \
    #   --name ssh-myip \
    #   --description "${MYIPADDR}->${PIPADDR[${COMPONENT}-${TYPE}]}:${PORT[ssh]}" \
    #   --priority 100 \
    #   --source-address-prefixes ${MYIPADDR} \
    #   --destination-address-prefixes ${PIPADDR[${COMPONENT}-${TYPE}]} \
    #   --destination-port-ranges ${PORT[ssh]} \
    #   --protocol Tcp \
    #   >>${LOG} 2>&1 || exit 1
    # echo " done. (${MYIPADDR}->${PIPADDR[${COMPONENT}-${TYPE}]}:${PORT[ssh]})"

    echo -n "creating ${COMPONENT}-${TYPE}-nsg-rule.."
    az network nsg rule create \
      --resource-group ${RG} \
      --nsg-name ${COMPONENT}-${TYPE}-nsg \
      --name ssh-myip \
      --description "wide open ssh" \
      --priority 100 \
      --destination-port-ranges ${PORT[ssh]} \
      --destination-address-prefix ${PIPADDR[${COMPONENT}-${TYPE}]} \
      --direction Inbound \
      --protocol Tcp \
      >>${LOG} 2>&1 || exit 1
    echo " done. (${MYIPADDR}->${PIPADDR[${COMPONENT}-${TYPE}]}:${PORT[ssh]})"

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

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  if [[ ${COMPONENT} == "source" ]]
  then
    OTHER="destination"
  else
    OTHER="source"
  fi

  echo -n "creating ${COMPONENT}-gw-nsg-rule.."
  az network nsg rule create \
    --resource-group ${RG} \
    --nsg-name ${COMPONENT}-gw-nsg \
    --name wireguard-hop \
    --description "${PIPADDR[${OTHER}-gw]}->${PIPADDR[${COMPONENT}-gw]}:${PORT[wireguard]}" \
    --priority 103 \
    --source-address-prefixes ${PIPADDR[${OTHER}-gw]} \
    --destination-address-prefixes ${PIPADDR[${COMPONENT}-gw]} \
    --destination-port-ranges ${PORT[wireguard]} \
    --protocol Udp \
    >>${LOG} 2>&1 || exit 1
  echo " done. (${PIPADDR[${OTHER}-gw]}->${PIPADDR[${COMPONENT}-gw]}:${PORT[wireguard]})"
done

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
      >>${LOG} 2>&1 || exit 1
    echo " done."
  done
done

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  for TYPE in vm gw; do
    echo "${COMPONENT}-${TYPE}: ${PIPADDR[${COMPONENT}-${TYPE}]} | ${PRIVIPADDR[${COMPONENT}-${TYPE}]}"
  done
done

echo "done."
