# Tailscale Operator on EKS: API Server Proxy + Cluster Egress Demo

This repo stands up an EKS cluster with the Tailscale Kubernetes Operator. It demonstrates:

- API Server Proxy: `kubectl` to a private EKS API via the operator’s Tailscale device  
- Cluster Egress to a tailnet node from a pod using a simple `Service`

## Prereqs

- Terraform, AWS CLI, kubectl, Helm
- An AWS account and credentials
- A Tailscale tailnet with an OAuth client (client_id / client_secret)
- Your machine is on the tailnet (Tailscale app running)

## What Terraform Creates

- **VPC with private subnets and routing**  
- **EKS control plane** (initially with a public API endpoint until the proxy is ready, then private-only)  
- **2 EC2 instances** (EKS managed node group, `t3.medium`)  
- **IAM roles and security groups** for the cluster and worker nodes  
- **CloudWatch log group** for API server logs  
- **KMS key and alias** for encrypting Kubernetes secrets at rest 


## What Kubernetes/Helm Creates

- **Namespace** (`tailscale`) to isolate operator resources  
- **Secret** (`operator-oauth`) containing the Tailscale OAuth client credentials  
- **Tailscale Operator Deployment** (via Helm chart `tailscale/tailscale-operator`)  
- **Custom Resource Definitions (CRDs)** that enable API Server Proxy, egress, ingress, and connector features  
- **API Server Proxy** device inside the tailnet, providing secure `kubectl` access without public endpoints  
- **Cluster egress Service** annotated with a tailnet IP, routing pod traffic through the tailnet  
- **Test pod** (`testbox`) for validating egress and MagicDNS lookups

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

```bash
cd kubernetes/operator

kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-operator-oauth-secret.yaml

helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  -n tailscale \
  --values values.yaml \
  --wait
```

Verify:

```bash
kubectl -n tailscale get deploy,po
kubectl -n tailscale logs deploy/operator --tail=50
```

Look for: `API server proxy in noauth mode is listening on :443`

## 5) Point kubectl at the API Server Proxy

```bash
export TS_URL="https://tailscale-operator.<tailnet>.ts.net:443"

CUR_USER=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.user}')

kubectl config set-cluster ts-proxy --server="$TS_URL"
kubectl config unset clusters.ts-proxy.certificate-authority      2>/dev/null
kubectl config unset clusters.ts-proxy.certificate-authority-data 2>/dev/null
kubectl config set-context ts-proxy --cluster=ts-proxy --user="$CUR_USER"
kubectl config use-context ts-proxy
```

Verify:

```bash
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

## 6) Lock down the EKS API to private only

`terraform/main.tf` should contain be set with:

```hcl
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = false
```

Apply only the EKS module:

```bash
cd terraform
terraform apply -target=module.eks
```
Your `ts-proxy` context will continue working. The public context will stop.

## 7) Prove the API Proxy tunnel works

With your Tailscale client **connected**, the proxy responds:

```bash
kubectl get nodes
```

Disconnect or disable your local Tailscale client, then try again:

```bash
kubectl get nodes
# This should fail to connect, proving the API is private and only reachable over Tailscale
```

You can also grab the EKS cluster endpoint information via awscli:

```bash
aws eks describe-cluster \
  --name tailscale-demo-cluster \
  --region us-east-1 \
  --query "cluster.resourcesVpcConfig.{Public: endpointPublicAccess, Private: endpointPrivateAccess}"
```

## 8) Egress demo

Modify the tailnet-service.yaml file so it has your actual tailnet IP

```bash
cd ../kubernetes/egress
kubectl apply -f tailnet-service.yaml
kubectl apply -f testbox-pod.yaml
kubectl wait --for=condition=Ready pod/testbox --timeout=120s
```

On your laptop (I used elevated PowerShell for this simple web server)

I ran this from a directory that had a text file in it "myfile.txt", also replace bind address with your actual tailnet IP value

```powershell
python3 -m http.server 8000 --bind <your-tailnet-ip>
```

Inside the testbox pod:

```bash
kubectl exec -it testbox -- sh -lc 'wget -q -O- http://tailnet-egress-demo:8000/myfile.txt'
```

You should see the file contents returned.

```bash
kubectl exec -it testbox -- sh -lc 'wget -q -O- http://tailnet-egress-demo:8000/myfile.txt'

it works!

myfile.txt has my awesome content.
```

## Useful checks

```bash
kubectl config current-context
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl -n tailscale logs deploy/operator --tail=200 | grep -i "listening on :443"
nc -vz tailscale-operator.<tailnet>.ts.net 443
curl -vk https://tailscale-operator.<tailnet>.ts.net/livez
```

## Notes

- A secrets manager is always recommended for PROD, but for this simple proof of concept we can skip it.
- In this guide the proxy runs in noauth mode, relying on AWS IAM auth from kubeconfig.  
- If `kubectl` asks for a username, you're on a context missing exec auth. Switch back to `ts-proxy` or rebuild it.
