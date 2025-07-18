# Version variables
CILIUM_VERSION = 1.17.6
GATEWAY_API_VERSION = v1.2.0
KUBERNETES_VERSION = v1.31.2

.PHONY: help setup-infrastructure create-cluster install-cilium delete-cluster deploy-argocd cleanup-argocd get-argocd-password install-argo-rollouts cleanup-argo-rollouts start-port-forwards stop-port-forwards status clean all

# Create Kind cluster only
create-cluster:
	@echo "🚀 Creating Kind cluster with custom configuration..."
	kind create cluster --config=kind-config.yaml
	@echo "✅ Kind cluster created successfully!"
	@echo ""
	@echo "💡 Next step: Run 'make install-cilium' to install Cilium and Gateway API"

# Install Cilium and Gateway API on existing cluster
install-cilium:
	@echo "📦 Adding Cilium Helm repository..."
	helm repo add cilium https://helm.cilium.io/
	@echo "🌐 Installing Gateway API CRDs (standard)..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
	@echo "🧪 Installing Gateway API CRDs (experimental)..."
	kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/$(GATEWAY_API_VERSION)/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
	@echo "🔷 Installing Cilium with Gateway API support and kube-proxy replacement..."
	helm install cilium cilium/cilium --version $(CILIUM_VERSION) \
		--namespace kube-system \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set image.pullPolicy=IfNotPresent \
		--set ipam.mode=kubernetes \
		--set nodePort.enabled=true \
		--set kubeProxyReplacement=true \
		--set k8sServiceHost=kind-control-plane \
		--set k8sServicePort=6443 \
		--set l7Proxy=true \
		--set gatewayAPI.enabled=true
	@echo "📊 Installing metrics-server for resource monitoring..."
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	@echo "🔧 Patching metrics-server for Kind cluster compatibility..."
	kubectl patch deployment metrics-server -n kube-system \
		--type=json \
		-p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
	@echo "✅ Cilium and Gateway API installed successfully!"

# Complete infrastructure setup (cluster + cilium)
setup-infrastructure: create-cluster install-cilium
	@echo "🎉 Infrastructure setup completed!"

# Delete Kind cluster
delete-cluster:
	@echo "🗑️  Deleting Kind cluster..."
	kind delete cluster -n kind
	@echo "✅ Cluster deleted!"

# Deploy ArgoCD with custom configuration
deploy-argocd:
	@echo "🚀 Deploying ArgoCD with custom configuration..."
	@echo "📦 Creating argocd namespace..."
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	@echo "📦 Adding ArgoCD Helm repository..."
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update
	@echo "🔧 Installing ArgoCD with custom values..."
	helm install argocd argo/argo-cd \
		-n argocd \
		-f k8s-manifests/argocd/values.yaml \
		--skip-crds
	@echo "⏳ Waiting for ArgoCD pods to be ready..."
	kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
	@echo ""
	@echo "📋 ArgoCD Deployment Status:"
	kubectl get pods -n argocd
	@echo ""
	@echo "🔗 ArgoCD Service Status:"
	kubectl get service -n argocd
	@echo ""
	@echo "✅ ArgoCD deployment completed!"
	@echo ""
	@echo "🔑 Getting ArgoCD admin password..."
	@$(eval ARGOCD_PASSWORD := $(shell kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d))
	@echo "📋 ArgoCD Access Information:"
	@echo "   Username: admin"
	@echo "   Password: $(ARGOCD_PASSWORD)"
	@echo ""
	@echo "💡 To access ArgoCD:"
	@echo "   Run: kubectl port-forward service/argocd-server -n argocd 8080:80"
	@echo "   Then open: http://localhost:8080"

# Remove ArgoCD installation
cleanup-argocd:
	@echo "🗑️  Removing ArgoCD installation..."
	helm uninstall argocd -n argocd || true
	@echo "🗂️  Removing argocd namespace..."
	kubectl delete namespace argocd --ignore-not-found=true
	@echo "✅ ArgoCD removal completed!"

# Get ArgoCD admin password
get-argocd-password:
	@echo "🔑 Getting ArgoCD admin password..."
	@if kubectl get secret argocd-initial-admin-secret -n argocd >/dev/null 2>&1; then \
		echo "📋 ArgoCD Access Information:"; \
		echo "   Username: admin"; \
		echo "   Password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"; \
		echo ""; \
		echo "💡 To access ArgoCD:"; \
		echo "   Run: kubectl port-forward service/argocd-server -n argocd 8080:80"; \
		echo "   Then open: http://localhost:8080"; \
	else \
		echo "❌ ArgoCD admin secret not found. Make sure ArgoCD is deployed first."; \
		echo "💡 Run 'make deploy-argocd' to deploy ArgoCD"; \
	fi

# Install Argo Rollouts controller
install-argo-rollouts:
	@echo "🚀 Installing Argo Rollouts controller..."
	@echo "📦 Creating argo-rollouts namespace..."
	kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
	@echo "📦 Installing Argo Rollouts CRDs and controller..."
	kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
	@echo "⏳ Waiting for Argo Rollouts controller to be ready..."
	kubectl wait --for=condition=available deployment/argo-rollouts -n argo-rollouts --timeout=300s
	@echo ""
	@echo "📋 Argo Rollouts Deployment Status:"
	kubectl get pods -n argo-rollouts
	@echo ""
	@echo "✅ Argo Rollouts installation completed!"
	@echo ""
	@echo "💡 Argo Rollouts is now ready to manage Rollout resources"
	@echo "💡 You can now use 'kubectl apply' with Rollout manifests"

# Remove Argo Rollouts installation
cleanup-argo-rollouts:
	@echo "🗑️  Removing Argo Rollouts installation..."
	kubectl delete -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml --ignore-not-found=true
	@echo "🗂️  Removing argo-rollouts namespace..."
	kubectl delete namespace argo-rollouts --ignore-not-found=true
	@echo "✅ Argo Rollouts removal completed!"

# Start port forwarding for services
start-port-forwards:
	@echo "📡 Starting Port Forwarding for services..."
	@echo "🔗 ArgoCD: http://localhost:8080"
	@echo "🔗 Hubble UI: http://localhost:12000"
	@echo ""
	@echo "Starting port forwards in background..."
	@pkill -f "port-forward.*argocd-server" || true
	@pkill -f "port-forward.*hubble-ui" || true
	@sleep 2
	@kubectl port-forward service/argocd-server -n argocd 8080:80 > /dev/null 2>&1 &
	@kubectl port-forward service/hubble-ui -n kube-system 12000:80 > /dev/null 2>&1 &
	@sleep 3
	@echo "✅ Port forwarding started!"
	@echo ""
	@echo "🌐 Services available at:"
	@echo "   ArgoCD: http://localhost:8080"
	@echo "   Hubble UI: http://localhost:12000"
	@echo ""
	@echo "💡 Run 'make stop-port-forwards' to stop port forwarding"

# Stop port forwarding
stop-port-forwards:
	@echo "🛑 Stopping Port Forwarding..."
	@pkill -f "port-forward.*argocd-server" || true
	@pkill -f "port-forward.*hubble-ui" || true
	@echo "✅ Port forwarding stopped!"

# Show cluster and application status
status:
	@echo "📊 Cluster and Application Status"
	@echo ""
	@echo "🔷 Cilium Status:"
	@kubectl get pods -n kube-system -l k8s-app=cilium
	@echo ""
	@echo "🌐 Gateway API Resources:"
	@kubectl get gateway,httproute -A 2>/dev/null || echo "   No Gateway API resources found"
	@echo ""
	@echo "📦 ArgoCD Pods:"
	@kubectl get pods -n argocd 2>/dev/null || echo "   No ArgoCD pods found"
	@echo ""
	@echo "🔗 ArgoCD Services:"
	@kubectl get service -n argocd 2>/dev/null || echo "   No ArgoCD services found"

# Remove all resources and cluster
clean: cleanup-argocd cleanup-argo-rollouts delete-cluster
	@echo "🧹 All resources and cluster removed!"

# Complete setup and deploy ArgoCD
all: setup-infrastructure deploy-argocd install-argo-rollouts
	@echo "🎉 Complete setup finished! ArgoCD and Argo Rollouts deployed!"

# Default target
help:
	@echo "🚀 Cilium Gateway API Demo - Makefile Commands"
	@echo ""
	@echo "📋 Version Information:"
	@echo "  Kubernetes Version: $(KUBERNETES_VERSION)"
	@echo "  Cilium Version: $(CILIUM_VERSION)"
	@echo "  Gateway API Version: $(GATEWAY_API_VERSION)"
	@echo ""
	@echo "📋 Infrastructure Commands:"
	@echo "  setup-infrastructure - Create cluster and install Cilium (complete setup)"
	@echo "  create-cluster       - Create Kind cluster only"
	@echo "  install-cilium       - Install Cilium and Gateway API on existing cluster"
	@echo "  delete-cluster       - Delete Kind cluster"
	@echo ""
	@echo "📋 Application Commands:"
	@echo "  deploy-argocd        - Deploy ArgoCD with custom configuration"
	@echo "  cleanup-argocd       - Remove ArgoCD installation"
	@echo "  get-argocd-password  - Get ArgoCD admin password"
	@echo "  install-argo-rollouts - Install Argo Rollouts controller"
	@echo "  cleanup-argo-rollouts - Remove Argo Rollouts installation"
	@echo "  start-port-forwards  - Start port forwarding for local access"
	@echo "  stop-port-forwards   - Stop port forwarding"
	@echo ""
	@echo "📋 Utility Commands:"
	@echo "  status               - Show cluster and application status"
	@echo "  clean                - Remove all resources and cluster"
	@echo "  all                  - Complete setup + deploy ArgoCD + Argo Rollouts"
	@echo ""