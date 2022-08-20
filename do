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
#PREFIX[source]=100.64.0
#PREFIX[destination]=100.64.1
PREFIX[source]=192.168.0
PREFIX[destination]=192.168.1
PREFIXLEN[source]=/24
PREFIXLEN[destination]=/24
MYIPADDR=`curl -fs 'https://api.ipify.org' | cut -f1,2,3 -d.`.0/24
#MYIPADDR=`curl -fs 'https://api.ipify.org'`/32
#MYIPADDR=`dig +short myip.opendns.com @resolver1.opendns.com`/32
echo "my IP prefix is ${MYIPADDR}"
#echo "my IP address is ${MYIPADDR}"
PORT[ssh]=22
PORT[wireguard]=51820
SUBNETSUFFIX[gw]=16
SUBNETSUFFIX[vm]=17
CONFIG=./config
ACCELNET="--accelerated-networking"
VMSKU=Standard_D2s_v5
#UBUNTUIMAGEURN=UbuntuLTS
#UBUNTUIMAGEURN=Canonical:0001-com-ubuntu-minimal-jammy:minimal-22_04-lts-gen2:22.04.202208100
UBUNTUIMAGEURN=Canonical:0001-com-ubuntu-server-jammy-daily:22_04-daily-lts-gen2:22.04.202208100
LOG=${PROJ}.log



# Check if Azure CLI exists

echo -n "checking for Azure CLI.."
az 2>&1 >/dev/null
if [ $? -eq 0 ]
then
  echo " found."
else
  echo " not found.. Install Azure CLI or check installation."
  exit 1
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
echo "found readable config file (${CONFIG})."


# emit set SSH port, can be changed in config file

echo "SSH port: ${PORT[ssh]}"
echo "Wireguard port: ${PORT[wireguard]}"

# Advise on creds

if [[ -z ${ADMINUSER} ]]
then
  echo "ADMINUSER parameter in file ${CONFIG} missing. aborting." && exit 1
fi
if [[ -z ${ADMINPASS} ]]
then
  echo "ADMINPASS parameter in file ${CONFIG} missing (must match Azure password rules). aborting." && exit 1
fi
echo "credentials found in ${CONFIG}. (${ADMINUSER})"


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


# Check if yaml-proto configs exist

for COMPONENT in source destination; do
  for TYPE in vm gw; do
    if [[ -r ${COMPONENT}-${TYPE}-init.yaml-proto ]]
    then
      echo "found readable ${COMPONENT}-${TYPE}-init.yaml-proto."
    else
      echo "cloud-init prototype YAML for ${COMPONENT}-${TYPE} doesn't exist. exiting." && exit 1
    fi
  done
done


# Generate cloud-init .yaml's from -proto's

echo -n "generate cloud-init .yaml's for VM's from .yaml-proto's.."
for COMPONENT in source destination; do 
  for TYPE in gw vm; do
    sed -e "s/SSHPORT/${PORT[ssh]}/" ${COMPONENT}-${TYPE}-init.yaml-proto > ${COMPONENT}-${TYPE}-init.yaml >>${LOG} 2>&1 || exit 1
  done
done
echo " done."


# Check if resource group exists, create it if it does not or delete if it does, unless it's shared rg

for COMPONENT in shared source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  echo -n "rg ${RG} does"
  if [[ "`az group exists --name ${RG}`" == "true" ]]; 
  then
    echo -n " exist.."
    if [[ "${COMPONENT}" == "shared" ]]; 
    then
      echo " preserved."
    else
      echo -n " deleting.."
      az group delete \
        --resource-group ${RG} \
        --yes \
        --only-show-errors \
        >${LOG} 2>&1 || exit 1
    fi
  else
    echo -n "n't exist.."
  fi
  if [[ "`az group exists --name ${RG}`" == "false" ]]; 
  then
    echo -n " creating.."
    az group create \
      --name ${RG} \
      --location ${LOCATION} \
      >>${LOG} 2>&1 || exit 1
    echo " done."
  fi
done


# Create shared storage

RG=${PROJ}-shared-rg
echo -n "checking storage account ${PROJ}shared.."
if [[ "`az storage account check-name --name pnatshared --query nameAvailable`" == "true" ]]; then
  echo -n " creating account.."
  az storage account create \
    --resource-group ${RG} \
    --location ${LOCATION} \
    --name ${PROJ}shared \
    --sku Premium_LRS \
    --kind FileStorage \
    --enable-large-file-share \
    --quiet \
    >>${LOG} 2>&1 || exit 1

# Create share

    echo -n "creating share.."
    az storage share-rm create \
      --resource-group ${RG} \
      --name share \
      --storage-account ${PROJ}shared \
      --enabled-protocols smb \
      --quota 100 \
      >>${LOG} 2>&1 || exit 1
    echo " done."
else 
  echo " exists and presumed correct."
fi


# populate SMB credentials on gw VM's

echo "pushing SMB credentials into .yaml's.."
for COMPONENT in source destination; do
  mv ${COMPONENT}-${TYPE}-init.yaml ${COMPONENT}-${TYPE}-init.yaml-pre
  sed -e "s/SMBACCOUNTNAME/foo/" ${COMPONENT}-${TYPE}-init.yaml-pre > ${COMPONENT}-${TYPE}-init.yaml >>${LOG} 2>&1 || exit 1
  mv ${COMPONENT}-${TYPE}-init.yaml ${COMPONENT}-${TYPE}-init.yaml-pre
  sed -e "s/SMBACCOUNTKEY/bar/" ${COMPONENT}-${TYPE}-init.yaml-pre > ${COMPONENT}-${TYPE}-init.yaml >>${LOG} 2>&1 || exit 1
done
echo " done."


# Do all the networking things

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg

# Create vnets

  echo -n "deploying ${COMPONENT}-vnet and ${COMPONENT}-subnet.."
  az network vnet create \
    --resource-group ${RG} \
    --name ${COMPONENT}-vnet \
    --address-prefix ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    --subnet-name ${COMPONENT}-subnet \
    --subnet-prefixes ${PREFIX[${COMPONENT}]}.0${PREFIXLEN[${COMPONENT}]} \
    >>${LOG} 2>&1 || exit 1
  echo " done."
done

# Get storage account ID 

storageAccountID=$(az storage account show \
        --resource-group ${PROJ}-shared-rg \
        --name ${PROJ}shared \
        --query "id" | \
    tr -d '"') && \
echo "got storage account ID ref."

# Iterate through the vnets/subnets to create local PE's for storage and register in private DNS zone

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  echo "> Deploying ${RG}"

#  Disable PE network policies

  echo -n "disabling PE network policies on ${COMPONENT}-subnet.."
  az network vnet subnet update \
    --resource-group ${RG} \
    --name ${COMPONENT}-subnet \
    --vnet-name ${COMPONENT}-vnet \
    --disable-private-endpoint-network-policies true \
    --output none && \
    echo " done."

# creating PE

  echo "creating PE."
  peID=$(az network private-endpoint create \
    --resource-group ${RG} \
    --name ${PROJ}shared-pe \
    --vnet-name ${COMPONENT}-vnet \
    --subnet ${COMPONENT}-subnet \
    --private-connection-resource-id ${storageAccountID} \
    --group-id "file" \
    --connection-name "${PROJ}shared" \
    --query "id" | tr -d '"')  && \

# private DNS setup for vnet

  echo -n "creating ${COMPONENT}.io private DNS zone.."
  az network private-dns zone create \
    --resource-group ${RG} \
    --name "${COMPONENT}.io" \
    >>${LOG} 2>&1 || exit 1
  echo " done."

  echo -n "linking private DNS to vnet.."
  az network private-dns link vnet create \
    --resource-group ${RG} \
    --name ${COMPONENT}-link \
    --zone-name "${COMPONENT}.io" \
    --virtual-network ${COMPONENT}-vnet \
    --registration-enabled true \
    >>${LOG} 2>&1 || exit 1
  echo " done."
  
# Create private DNS records for PE

  peNIC=$(az network private-endpoint show \
    --ids ${peID} \
    --query "networkInterfaces[0].id" | \
    tr -d '"')
  echo "PE NIC identified."

  peIP=$(az network nic show \
    --ids ${peNIC} \
    --query "ipConfigurations[0].privateIpAddress" | \
    tr -d '"')
  echo "PE IP: ${peIP}."

  echo -n "creating A record to ${peIP} for share.${COMPONENT}.io.."
  az network private-dns record-set a create \
    --resource-group ${RG} \
    --zone-name "${COMPONENT}.io" \
    --name share \
    --output none

  az network private-dns record-set a add-record \
    --resource-group ${RG} \
    --zone-name "${COMPONENT}.io" \
    --record-set-name share \
    --ipv4-address $peIP \
    --output none
  echo " done."

# Create public IPs and retrieve the addr
  echo "> Rest of networking for ${RG}"

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
    echo " done. (${PIPADDR[${COMPONENT}-${TYPE}]})"


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
      --name myip \
      --description "Not so wide open ssh" \
      --priority 100 \
      --destination-address-prefixes '*' \
      --destination-port-ranges ${PORT[ssh]} \
      --source-address-prefixes ${MYIPADDR} \
      --source-port-ranges '*' \
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
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges ${PORT[wireguard]} \
    --direction Inbound \
    --protocol Udp \
    >>${LOG} 2>&1 || exit 1
  echo " done. (${PIPADDR[${OTHER}-gw]}->${PIPADDR[${COMPONENT}-gw]}:${PORT[wireguard]})"
done

# Create our VMs
echo "> Building VMs"

for COMPONENT in source destination; do
  RG=${PROJ}-${COMPONENT}-rg
  for TYPE in vm gw; do
    echo -n "creating ${COMPONENT} ${TYPE} VM.."
    az vm create \
      --resource-group ${RG} \
      --name ${COMPONENT}-${TYPE} \
      --image ${UBUNTUIMAGEURN} \
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

(
  for COMPONENT in source destination; do
    RG=${PROJ}-${COMPONENT}-rg
    for TYPE in vm gw; do
      echo "${COMPONENT}-${TYPE}: ${PIPADDR[${COMPONENT}-${TYPE}]} | ${PRIVIPADDR[${COMPONENT}-${TYPE}]}"
    done
  done
) | tee -a ${LOG}


# Everything _should_ be done by the time we get here. "GOOD LUCK."

echo "done."
