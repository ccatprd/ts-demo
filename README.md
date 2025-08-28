# Tailscale Operator on EKS: API Server Proxy + Cluster Egress Demo

This repo stands up an EKS cluster with the Tailscale Kubernetes Operator. It demonstrates:

- API Server Proxy: `kubectl` to a private EKS API via the operator’s Tailscale device  
- Cluster Egress to a tailnet node from a pod using a simple `Service`

## Prereqs

- Terraform, AWS CLI, kubectl, Helm
- An AWS account and credentials
- A Tailscale tailnet with an OAuth client (client_id / client_secret)
- Your machine is on the tailnet (Tailscale app running)

## 1) Clone and set custom values

```bash
git clone https://github.com/ccatprd/ts-demo
cd ts-demo
```

Edit `terraform/main.tf` and set the EKS endpoint public **temporarily**:

```hcl
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = true
```

Edit `kubernetes/operator/01-operator-oauth-secret.yaml` with your real OAuth client:

```yaml
stringData:
  client_id: "tsc_xxx"
  client_secret: "tskey-client-xxx"
```

`kubernetes/operator/values.yaml` should look like this:

```yaml
oauth:
  existingSecret: operator-oauth

apiServerProxyConfig:
  mode: "noauth"

operatorConfig:
  defaultTags: "tag:k8s-operator"

proxyConfig:
  defaultTags: "tag:k8s"
```

## 2) Terraform apply

```bash
cd terraform
terraform init
terraform plan
terraform apply -auto-approve
```

## 3) Bootstrap kubectl to the public EKS endpoint

```bash
export CLUSTER=tailscale-demo-cluster
export AWS_REGION=us-east-1

aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl get nodes
```

You should see two Ready nodes.

## 4) Install the Tailscale Operator

From the repo root:

```bash
cd kubernetes/operator

# namespace + secret
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-operator-oauth-secret.yaml

# install via Helm using values.yaml
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update
helm upgrade --install tailscale-operator tailscale/tailscale-operator   -n tailscale   --values values.yaml   --wait
```

Verify:

```bash
kubectl -n tailscale get deploy,po
kubectl -n tailscale logs deploy/operator --tail=50
```

You should see a log line like: `API server proxy in noauth mode is listening on :443`.

## 5) Point kubectl at the API Server Proxy

Create a new context that reuses your current AWS IAM user but dials the operator’s Tailscale URL:

```bash
export TS_URL="https://tailscale-operator.<tailnet>.ts.net:443"

# reuse the current user entry created by aws eks update-kubeconfig
CUR_USER=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.user}')

kubectl config set-cluster ts-proxy --server="$TS_URL"
kubectl config unset clusters.ts-proxy.certificate-authority      2>/dev/null || true
kubectl config unset clusters.ts-proxy.certificate-authority-data 2>/dev/null || true
kubectl config set-context ts-proxy --cluster=ts-proxy --user="$CUR_USER"
kubectl config use-context ts-proxy
```

Verify you’re using the proxy:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
# expect: https://tailscale-operator.<tailnet>.ts.net:443

kubectl get nodes
```

## 6) Lock down the EKS API to private only

Flip the endpoint back to private:

```hcl
# terraform/main.tf
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = false
```

Apply just the EKS module:

```bash
cd terraform
terraform apply -target=module.eks
```

Your `ts-proxy` context keeps working. The old public context will stop.

## 7) Egress demo

Prepare the egress `Service` and a test pod. Make sure your `tailnet-service.yaml` has your real tailnet IP set.

```bash
cd ../kubernetes/egress
kubectl apply -f tailnet-service.yaml
kubectl apply -f testbox-pod.yaml
kubectl wait --for=condition=Ready pod/testbox --timeout=120s
```

Spin up a simple web server on your laptop (Windows PowerShell as admin):

```powershell
python3 -m http.server 8000 --bind <your-tailnet-ip>
```

From inside the testbox pod, fetch a file through the egress Service:

```bash
kubectl exec -it testbox -- sh -lc 'wget -q -O- http://tailnet-egress-demo:8000/myfile.txt'
```

You should see the file contents returned. That proves pod egress to your tailnet node.

## Useful checks

Current context:

```bash
kubectl config current-context
```

Which server kubectl is dialing:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

Operator listening:

```bash
kubectl -n tailscale logs deploy/operator --tail=200 | grep -i "listening on :443"
```

TCP/HTTPS reachability to the operator device:

```bash
nc -vz tailscale-operator.<tailnet>.ts.net 443
curl -vk https://tailscale-operator.<tailnet>.ts.net/livez
```

## Notes

- Do not commit real OAuth credentials. Keep `01-operator-oauth-secret.yaml` local.
- In this guide the proxy is `noauth`, so IAM auth from your kubeconfig is used end to end.
- If `kubectl` ever prompts for a username, you’re on a context with no exec auth configured. Switch back to `ts-proxy` or rebuild it as shown above.
