
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Single-node RKE2 + Rancher + PostgreSQL + Keycloak
# Intended for a dedicated Ubuntu management server.
# Requires working DNS, ingress, storage, and Internet access.

export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

log() { echo -e "\n[$(date '+%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "FAILED at line $LINENO" >&2' ERR

[[ $EUID -eq 0 ]] || die "Run as root"

read -rp "Rancher domain [rancherinji.idencode.link]: " RANCHER_DOMAIN
RANCHER_DOMAIN=${RANCHER_DOMAIN:-rancherinji.idencode.link}

read -rp "Keycloak domain [keycloak.idencode.link]: " KC_DOMAIN
KC_DOMAIN=${KC_DOMAIN:-keycloak.idencode.link}

read -rp "RKE2 version [v1.34.12+rke2r1]: " RKE2_VERSION
RKE2_VERSION=${RKE2_VERSION:-v1.34.12+rke2r1}

read -rp "Rancher version [2.15.3]: " RANCHER_VERSION
RANCHER_VERSION=${RANCHER_VERSION:-2.15.3}

read -rp "PostgreSQL StorageClass [local-path]: " STORAGE_CLASS
STORAGE_CLASS=${STORAGE_CLASS:-local-path}

read -rp "PostgreSQL storage size [20Gi]: " PG_SIZE
PG_SIZE=${PG_SIZE:-20Gi}

echo
echo "SSL certificate options:"
echo "1) Let's Encrypt (automatic)"
echo "2) Existing certificate files"
read -rp "Choose [1]: " CERT_MODE
CERT_MODE=${CERT_MODE:-1}

case "$CERT_MODE" in
  1)
    read -rp "Let's Encrypt email: " LE_EMAIL
    [[ -n "$LE_EMAIL" ]] || die "Email required"
    ;;
  2)
    read -rp "Rancher fullchain PEM path: " R_CERT
    read -rp "Rancher private key PEM path: " R_KEY
    read -rp "Keycloak fullchain PEM path: " K_CERT
    read -rp "Keycloak private key PEM path: " K_KEY
    for f in "$R_CERT" "$R_KEY" "$K_CERT" "$K_KEY"; do
      [[ -s "$f" ]] || die "Missing or empty file: $f"
    done
    ;;
  *)
    die "Invalid certificate mode"
    ;;
esac

read -rsp "Rancher bootstrap password: " RANCHER_PASS
echo
read -rsp "Keycloak admin password: " KC_PASS
echo
read -rsp "PostgreSQL Keycloak DB password: " PG_PASS
echo
read -rsp "Keycloak OIDC client secret: " OIDC_SECRET
echo

for v in RANCHER_PASS KC_PASS PG_PASS OIDC_SECRET; do
  [[ -n "${!v}" ]] || die "$v must not be empty"
done

echo
echo "Rancher: https://$RANCHER_DOMAIN"
echo "Keycloak: https://$KC_DOMAIN"
echo "RKE2: $RKE2_VERSION"
echo "Rancher version: $RANCHER_VERSION"
echo "StorageClass: $STORAGE_CLASS"
read -rp "Type INSTALL to continue: " CONFIRM
[[ "$CONFIRM" == INSTALL ]] || exit 0

log "Installing prerequisites"
apt-get update
apt-get install -y curl ca-certificates jq openssl \
  tar gzip gettext-base python3 dnsutils

log "Checking existing installations"
if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
  die "Existing RKE2 installation detected. Refusing to modify it."
fi

if command -v kubectl >/dev/null 2>&1; then
  die "Existing kubectl installation detected; verify host is dedicated."
fi

log "Preparing RKE2 kernel configuration"
cat >/etc/modules-load.d/rke2.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/90-rke2.conf <<'EOF'
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
sysctl --system >/dev/null

log "Installing RKE2"
curl -fsSL https://get.rke2.io -o /tmp/install-rke2.sh
INSTALL_RKE2_TYPE=server \
INSTALL_RKE2_VERSION="$RKE2_VERSION" \
  sh /tmp/install-rke2.sh

systemctl enable --now rke2-server

export PATH="/var/lib/rancher/rke2/bin:$PATH"

log "Waiting for Kubernetes API"
for i in $(seq 1 120); do
  if kubectl get nodes >/dev/null 2>&1; then break; fi
  sleep 5
done

kubectl wait --for=condition=Ready node --all --timeout=600s

ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

log "Installing Helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  -o /tmp/get-helm-3.sh
bash /tmp/get-helm-3.sh

log "Checking storage and ingress"
kubectl get storageclass "$STORAGE_CLASS" >/dev/null \
  || die "StorageClass $STORAGE_CLASS does not exist"

kubectl -n kube-system rollout status \
  daemonset/rke2-ingress-nginx-controller \
  --timeout=300s || die "RKE2 ingress-nginx is not ready"

log "Installing cert-manager"
helm repo add jetstack https://charts.jetstack.io
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait --timeout 10m

kubectl create namespace cattle-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace keycloak \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "$CERT_MODE" == 1 ]]; then
  log "Creating Let's Encrypt ClusterIssuer"
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: "$LE_EMAIL"
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

  for entry in \
    "cattle-system rancher-tls $RANCHER_DOMAIN" \
    "keycloak keycloak-tls $KC_DOMAIN"; do
    read -r ns secret domain <<<"$entry"
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $secret
  namespace: $ns
spec:
  secretName: $secret
  dnsNames:
  - "$domain"
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
EOF
  done
else
  log "Installing existing TLS certificates"
  for item in "R_CERT R_KEY" "K_CERT K_KEY"; do
    read -r cert_var key_var <<<"$item"
    openssl x509 -in "${!cert_var}" -noout >/dev/null
    openssl pkey -in "${!key_var}" -noout >/dev/null
    cert_pub=$(openssl x509 -in "${!cert_var}" -pubkey -noout | openssl sha256)
    key_pub=$(openssl pkey -in "${!key_var}" -pubout | openssl sha256)
    [[ "$cert_pub" == "$key_pub" ]] || die "TLS key mismatch"
  done

  kubectl -n cattle-system create secret tls rancher-tls \
    --cert="$R_CERT" --key="$R_KEY"

  kubectl -n keycloak create secret tls keycloak-tls \
    --cert="$K_CERT" --key="$K_KEY"
fi

log "Installing Rancher"
helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version "$RANCHER_VERSION" \
  --set hostname="$RANCHER_DOMAIN" \
  --set bootstrapPassword="$RANCHER_PASS" \
  --set replicas=1 \
  --set ingress.tls.source=secret \
  --set ingress.tls.secretName=rancher-tls \
  --set ingress.ingressClassName=nginx \
  --wait --timeout 15m

log "Creating PostgreSQL credentials"
kubectl -n keycloak create secret generic keycloak-db \
  --from-literal=POSTGRES_PASSWORD="$PG_PASS"

kubectl -n keycloak create secret generic keycloak-admin \
  --from-literal=KC_BOOTSTRAP_ADMIN_PASSWORD="$KC_PASS"

kubectl -n keycloak create secret generic rancher-oidc \
  --from-literal=client-secret="$OIDC_SECRET"

log "Deploying PostgreSQL"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak-postgres
  namespace: keycloak
spec:
  clusterIP: None
  selector:
    app: keycloak-postgres
  ports:
  - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-postgres
  namespace: keycloak
spec:
  serviceName: keycloak-postgres
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-postgres
  template:
    metadata:
      labels:
        app: keycloak-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: keycloak
        - name: POSTGRES_USER
          value: keycloak
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-db
              key: POSTGRES_PASSWORD
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - pg_isready -U keycloak -d keycloak
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 1Gi
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: "$STORAGE_CLASS"
      resources:
        requests:
          storage: "$PG_SIZE"
EOF

kubectl -n keycloak rollout status \
  statefulset/keycloak-postgres --timeout=600s

log "Deploying Keycloak"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:26.4.0
        args: ["start"]
        ports:
        - containerPort: 8080
        env:
        - name: KC_DB
          value: postgres
        - name: KC_DB_URL
          value: jdbc:postgresql://keycloak-postgres.keycloak.svc.cluster.local:5432/keycloak
        - name: KC_DB_USERNAME
          value: keycloak
        - name: KC_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-db
              key: POSTGRES_PASSWORD
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: admin
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: keycloak-admin
              key: KC_BOOTSTRAP_ADMIN_PASSWORD
        - name: KC_HOSTNAME
          value: https://$KC_DOMAIN
        - name: KC_HTTP_ENABLED
          value: "true"
        - name: KC_PROXY_HEADERS
          value: xforwarded
        - name: KC_HEALTH_ENABLED
          value: "true"
        readinessProbe:
          tcpSocket:
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        resources:
          requests:
            cpu: 250m
            memory: 768Mi
          limits:
            memory: 2Gi
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - "$KC_DOMAIN"
    secretName: keycloak-tls
  rules:
  - host: "$KC_DOMAIN"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: keycloak
            port:
              number: 8080
EOF

kubectl -n keycloak rollout status \
  deployment/keycloak --timeout=900s

log "Creating Keycloak realm and Rancher OIDC client"

KC_POD=$(kubectl -n keycloak get pod \
  -l app=keycloak -o jsonpath='{.items[0].metadata.name}')

kubectl -n keycloak exec "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "$KC_PASS"

cat >/tmp/rancher-realm.json <<EOF
{
  "realm": "rancher",
  "enabled": true,
  "displayName": "Rancher Management",
  "clients": [
    {
      "clientId": "rancher",
      "name": "Rancher OIDC",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "$OIDC_SECRET",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": [
        "https://$RANCHER_DOMAIN/verify-auth-oidc"
      ],
      "webOrigins": [
        "https://$RANCHER_DOMAIN"
      ],
      "defaultClientScopes": [
        "web-origins",
        "acr",
        "roles",
        "profile",
        "email"
      ]
    }
  ]
}
EOF

kubectl -n keycloak cp /tmp/rancher-realm.json \
  "$KC_POD":/tmp/rancher-realm.json

kubectl -n keycloak exec "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh create realms \
  -f /tmp/rancher-realm.json

kubectl -n keycloak exec "$KC_POD" -- \
  rm -f /tmp/rancher-realm.json

rm -f /tmp/rancher-realm.json

log "Checking TLS certificates"
if [[ "$CERT_MODE" == 1 ]]; then
  kubectl -n cattle-system wait \
    --for=condition=Ready certificate/rancher-tls \
    --timeout=600s

  kubectl -n keycloak wait \
    --for=condition=Ready certificate/keycloak-tls \
    --timeout=600s
fi

log "Saving access information"
cat >/root/rancher-keycloak-access.txt <<EOF
Rancher URL: https://$RANCHER_DOMAIN
Rancher bootstrap user: admin

Keycloak URL: https://$KC_DOMAIN
Keycloak admin user: admin

Rancher OIDC settings:
Issuer: https://$KC_DOMAIN/realms/rancher
Client ID: rancher
Client secret: stored in Kubernetes secret keycloak/rancher-oidc
Callback: https://$RANCHER_DOMAIN/verify-auth-oidc

Activate the Keycloak OIDC provider in Rancher using
Users & Authentication > Auth Provider.

Do not disable Rancher local admin access until SSO is verified.
EOF

chmod 600 /root/rancher-keycloak-access.txt

echo
echo "============================================="
echo "INFRASTRUCTURE INSTALLATION COMPLETED"
echo "============================================="
echo "Rancher: https://$RANCHER_DOMAIN"
echo "Keycloak: https://$KC_DOMAIN"
echo
echo "Access details:"
echo "/root/rancher-keycloak-access.txt"
echo
echo "Next: Complete Rancher Keycloak OIDC browser verification."
echo "============================================="
