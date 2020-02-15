export OCUSER=$1
export OCPASSWD=$2
export MASTERPUBLICHOSTNAME=$3
export NAMESPACE=$4
export APIKEYUSERNAME=$5
export APIKEY=$6
export ARTIFACTSTOKEN=$7
export ARTIFACTSLOCATION=$8
export STORAGEOPTION=$9
export INSTALLERARTIFACTSLOCATION="https://prodcpdartifacts.blob.core.windows.net"
export HOME=/root

# Download Installer files
assembly="lite"
version="v2.5.0.0"
namespace=$NAMESPACE
storageclass=$STORAGEOPTION
mkdir -p /ibm/$assembly
export INSTALLERHOME=/ibm/$assembly
(cd $INSTALLERHOME && wget $INSTALLERARTIFACTSLOCATION/cpdinstaller/cpd-linux?$ARTIFACTSTOKEN -O cpd-linux)

if [[ $APIKEY == "" ]]; then
(cd $INSTALLERHOME && wget $INSTALLERARTIFACTSLOCATION/cpdinstaller/repo.yaml?$ARTIFACTSTOKEN -O repo.yaml)
else

(cd $INSTALLERHOME &&
cat > repo.yaml << EOF
registry:
  - url: cp.icr.io/cp/cpd
    username: $APIKEYUSERNAME
    apikey: $APIKEY
    name: base-registry
fileservers:
  - url: https://raw.github.com/IBM/cloud-pak/master/repo/cpd
EOF
)
fi
(cd $INSTALLERHOME && wget https://devocpartifacts.blob.core.windows.net/cpdinstaller/lutil?$ARTIFACTSTOKEN -O lutil)

chmod +x $INSTALLERHOME/cpd-linux
chmod +x $INSTALLERHOME/lutil

# Authenticate and Install
oc login -u ${OCUSER} -p ${OCPASSWD} ${MASTERPUBLICHOSTNAME} --insecure-skip-tls-verify=true

oc new-project $namespace
registry=$(oc get routes -n default | grep docker-registry | awk '{print $2}')

# Copy docker-registry certificate from master node
cat > /home/$OCUSER/fetch.yml << EOF
---
- hosts: master0
  tasks:
  - name: Copy cert to a user directory
    copy:
      src: "/etc/origin/node/client-ca.crt"
      dest: "/home/{{ user }}/node-client-ca.crt"
      remote_src: yes
    when: user is defined
  - name: Remote fetch docker-registry certificate from master0
    fetch:
      src: "/home/{{ user }}/node-client-ca.crt"
      dest: "/tmp/"
      flat: yes
    when: registry is defined
  - name: delete crt file
    file:
      path: "/home/{{ user }}/node-client-ca.crt"
      state: absent
- hosts: nodes
  tasks:
  - name: create directory
    file:
      path: /etc/docker/certs.d/{{ registry }}
      state: directory
  - name: Copy certs from default to custom domain
    copy:
      src: "/etc/docker/certs.d/docker-registry.default.svc:5000/node-client-ca.crt"
      dest: "/etc/docker/certs.d/{{ registry }}/"
      remote_src: yes
EOF

echo "Running fetch playbook"
runuser -l $OCUSER -c "ansible-playbook /home/$OCUSER/fetch.yml --extra-vars \"registry=$registry user=$OCUSER\""
runuser -l $OCUSER -c "rm -f /home/$OCUSER/fetch.yml"
echo "Fetch Playbook complete"

echo "Create docker registry certs folder"
mkdir -p /etc/docker/certs.d/$registry
echo "Create docker registry certs folder complete"

echo "Move cert to /etc/docker/certs.d/$registry/"
mv /tmp/node-client-ca.crt /etc/docker/certs.d/$registry/
echo "Move certs complete"

#Docker login
echo "$(date) Create Service Account token"
oc create serviceaccount cpdtoken
oc policy add-role-to-user admin system:serviceaccount:$namespace:cpdtoken
token=$(oc serviceaccounts get-token cpdtoken)

echo "Docker login to $registry registry"
docker login -u $(oc whoami) -p $token $registry
echo "Docker login complete"

#Run installer
cd $INSTALLERHOME

# Install CPD
echo "$(date) Begin Install"
./cpd-linux adm -r repo.yaml -a $assembly -n $namespace --accept-all-licenses --apply

./cpd-linux -c $storageclass -r repo.yaml -a $assembly -n $namespace \
    --transfer-image-to=$registry/$namespace --target-registry-username=$(oc whoami) \
    --target-registry-password=$token --accept-all-licenses

if [ $? -eq 0 ]
then
    echo $(date) " - Installation completed successfully"
else
    echo $(date) "- Installation failed"
    exit 11
fi

if [[ $APIKEY == "" ]]; then
wget https://devocpartifacts.blob.core.windows.net/cpdinstaller/activate-trial.py?$ARTIFACTSTOKEN -O activate-trial.py
wget https://devocpartifacts.blob.core.windows.net/cpdinstaller/trial.lic?$ARTIFACTSTOKEN -O trial.lic
cpdurl=$(oc get routes -n $namespace | grep $namespace-cpd | awk '{print $2}')
python activate-trial.py https://$cpdurl admin password trial.lic
rm -f trial.lic
fi

echo "Sleep for 30 seconds"
sleep 30
echo "Script Complete"
#==============================================================