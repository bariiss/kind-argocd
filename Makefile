# Version variables
CILIUM_VERSION = 1.17.6
GATEWAY_API_VERSION = v1.2.0
KUBERNETES_VERSION = v1.31.2

# Traffic generation parameters
TRAFFIC_TOTAL_REQUESTS = 100000
TRAFFIC_CONCURRENT_REQUESTS = 50
TRAFFIC_BATCHES = 10

.PHONY: help setup-infrastructure create-cluster install-cilium delete-cluster deploy-hello-world cleanup-hello-world deploy-argocd cleanup-argocd get-argocd-password start-port-forwards stop-port-forwards generate-gateway-traffic open-services status clean all

# Default target
help:
	@echo "🚀 Cilium Gateway API Demo - Makefile Commands"
	@echo ""
	@echo "📋 Version Information:"
	@echo "  Kubernetes Version: $(KUBERNETES_VERSION)"
	@echo "  Cilium Version: $(CILIUM_VERSION)"
	@echo "  Gateway API Version: $(GATEWAY_API_VERSION)"
	@echo ""
	@echo "📋 Traffic Generation Parameters:"
	@echo "  Total Requests: $(TRAFFIC_TOTAL_REQUESTS)"
	@echo "  Concurrent Requests: $(TRAFFIC_CONCURRENT_REQUESTS)"
	@echo "  Batches: $(TRAFFIC_BATCHES)"
	@echo "  💡 Modify these at the top of Makefile or override: make generate-gateway-traffic TRAFFIC_TOTAL_REQUESTS=2000"
	@echo ""
	@echo "📋 Infrastructure Commands:"
	@echo "  setup-infrastructure - Create cluster and install Cilium (complete setup)"
	@echo "  create-cluster       - Create Kind cluster only"
	@echo "  install-cilium       - Install Cilium and Gateway API on existing cluster"
	@echo "  delete-cluster       - Delete Kind cluster"
	@echo ""
	@echo "📋 Application Commands:"
	@echo "  deploy-hello-world   - Deploy hello-world application with Gateway API"
	@echo "  cleanup-hello-world  - Remove hello-world application resources"
	@echo "  deploy-argocd        - Deploy ArgoCD with custom configuration"
	@echo "  cleanup-argocd       - Remove ArgoCD installation"
	@echo "  get-argocd-password  - Get ArgoCD admin password"
	@echo "  start-port-forwards  - Start port forwarding for local access"
	@echo "  stop-port-forwards   - Stop port forwarding"
	@echo "  generate-gateway-traffic - Generate traffic through Gateway API (for Hubble)"
	@echo "  open-services        - Start port forwarding and open services in browser"
	@echo ""
	@echo "📋 Utility Commands:"
	@echo "  status               - Show cluster and application status"
	@echo "  clean                - Remove all resources and cluster"
	@echo "  all                  - Complete setup + deploy hello-world app"
	@echo ""

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

# Deploy demo application with Gateway API
deploy-hello-world:
	@echo "🚀 Deploying Hello-World Application with Gateway API..."
	@echo "📦 Applying all Kubernetes manifests..."
	kubectl apply -f k8s-manifests/hello-world/
	@echo "⏳ Waiting for pods to be ready..."
	kubectl wait --for=condition=ready pod -l app=hello-world -n hello-world --timeout=120s
	@echo "⏳ Waiting for gateway to be ready..."
	kubectl wait --for=condition=Programmed gateway/hello-world-gateway -n hello-world --timeout=120s
	@echo ""
	@echo "📋 Deployment Status:"
	kubectl get pods -l app=hello-world -n hello-world -o wide
	@echo ""
	@echo "🌐 Gateway Status:"
	kubectl get gateway hello-world-gateway -n hello-world
	kubectl get httproute hello-world-route -n hello-world
	@echo ""
	@echo "🔗 Service Status:"
	kubectl get service hello-world -n hello-world
	@echo ""
	@echo "📊 Gateway Details:"
	kubectl describe gateway hello-world-gateway -n hello-world
	@$(eval GATEWAY_IP := $(shell kubectl get gateway hello-world-gateway -n hello-world -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "Not assigned yet"))
	@echo ""
	@echo "✅ Deployment completed!"
	@echo ""
	@echo "🔗 Access Information:"
	@echo "   Gateway IP: $(GATEWAY_IP)"
	@echo "   Port: 8080"
	@echo ""
	@echo "📡 Starting Port Forwarding..."
	@echo "💡 Run 'make start-port-forwards' to enable local access"
	@echo "💡 Run 'make open-services' to open in browser"

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
		-f k8s-manifests/argocd/00-argocd-custom-values.yaml \
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

# Start port forwarding for services
start-port-forwards:
	@echo "📡 Starting Port Forwarding for services..."
	@echo "🔗 Gateway API Demo: http://localhost:8080"
	@echo "🔗 Hubble UI: http://localhost:12000"
	@echo ""
	@echo "Starting port forwards in background..."
	@pkill -f "port-forward.*hello-world" || true
	@pkill -f "port-forward.*hubble-ui" || true
	@sleep 2
	@kubectl port-forward service/hello-world -n hello-world 8080:80 > /dev/null 2>&1 &
	@kubectl port-forward service/hubble-ui -n kube-system 12000:80 > /dev/null 2>&1 &
	@sleep 3
	@echo "✅ Port forwarding started!"
	@echo ""
	@echo "🌐 Services available at:"
	@echo "   Demo App: http://localhost:8080"
	@echo "   Hubble UI: http://localhost:12000"
	@echo ""
	@echo "💡 Run 'make stop-port-forwards' to stop port forwarding"

# Stop port forwarding
stop-port-forwards:
	@echo "🛑 Stopping Port Forwarding..."
	@pkill -f "port-forward.*hello-world" || true
	@pkill -f "port-forward.*hubble-ui" || true
	@echo "✅ Port forwarding stopped!"

# Generate traffic through Gateway API (shows real L7 traffic in Hubble)
generate-gateway-traffic:
	@echo "🌐 Generating high-volume traffic through Gateway API..."
	@echo "📊 Traffic Parameters:"
	@echo "   Total Requests: $(TRAFFIC_TOTAL_REQUESTS)"
	@echo "   Concurrent Requests: $(TRAFFIC_CONCURRENT_REQUESTS)"
	@echo "   Batches: $(TRAFFIC_BATCHES)"
	@echo "   Target: Gateway API (/api/info endpoint)"
	@echo ""
	@echo "🚀 Starting traffic generation..."
	@kubectl run traffic-generator \
		--rm -i \
		--restart=Never \
		--image=curlimages/curl:latest \
		--env="GATEWAY_SERVICE=cilium-gateway-hello-world-gateway.hello-world" \
		--env="TOTAL_REQUESTS=$(TRAFFIC_TOTAL_REQUESTS)" \
		--env="CONCURRENT_REQUESTS=$(TRAFFIC_CONCURRENT_REQUESTS)" \
		--env="BATCHES=$(TRAFFIC_BATCHES)" \
		-- sh -c '\
			echo "Installing tools..."; \
			apk add --no-cache curl >/dev/null 2>&1; \
			echo "Starting intensive traffic generation..."; \
			echo "Target: http://$$GATEWAY_SERVICE:8080/api/info"; \
			echo "Total Requests: $$TOTAL_REQUESTS"; \
			echo "Concurrent Requests: $$CONCURRENT_REQUESTS"; \
			echo "Batches: $$BATCHES"; \
			echo ""; \
			BATCH_SIZE=$$((TOTAL_REQUESTS / BATCHES)); \
			echo "Requests per batch: $$BATCH_SIZE"; \
			echo ""; \
			TOTAL_SENT=0; \
			for batch in $$(seq 1 $$BATCHES); do \
				REQUESTS_THIS_BATCH=$$BATCH_SIZE; \
				if [ $$batch -eq $$BATCHES ]; then \
					REQUESTS_THIS_BATCH=$$((TOTAL_REQUESTS - TOTAL_SENT)); \
				fi; \
				echo "Batch $$batch/$$BATCHES - sending $$REQUESTS_THIS_BATCH requests..."; \
				for i in $$(seq 1 $$REQUESTS_THIS_BATCH); do \
					curl -s -H "Host: localhost" http://$$GATEWAY_SERVICE:8080/api/info >/dev/null & \
					if [ $$((i % CONCURRENT_REQUESTS)) -eq 0 ]; then \
						wait; \
					fi; \
				done; \
				wait; \
				TOTAL_SENT=$$((TOTAL_SENT + REQUESTS_THIS_BATCH)); \
				echo "  Sent $$REQUESTS_THIS_BATCH requests (Total: $$TOTAL_SENT/$$TOTAL_REQUESTS)"; \
				sleep 1; \
			done; \
			echo ""; \
			echo "Traffic generation complete! Sent: $$TOTAL_SENT requests"'
	@echo ""
	@echo "✅ High-volume traffic generation complete!"
	@echo "💡 Check Hubble UI now for intensive L7 traffic visibility in hello-world namespace"
	@echo "🔄 You should see $(TRAFFIC_TOTAL_REQUESTS) HTTP requests distributed across your pods!"

# Remove demo application resources
cleanup-hello-world:
	@echo "🗑️  Removing Hello-World Application..."
	@echo "🗂️  Removing all Kubernetes manifests..."
	kubectl delete -f k8s-manifests/hello-world/ --ignore-not-found=true
	@echo ""
	@echo "✅ All resources removed!"
	@echo ""
	@echo "📋 Checking Remaining Resources:"
	@kubectl get pods -l app=hello-world -n hello-world 2>/dev/null || echo "   ✅ Pods cleaned"
	@kubectl get service hello-world -n hello-world 2>/dev/null || echo "   ✅ Service cleaned"
	@kubectl get gateway hello-world-gateway -n hello-world 2>/dev/null || echo "   ✅ Gateway cleaned"
	@kubectl get httproute hello-world-route -n hello-world 2>/dev/null || echo "   ✅ HTTPRoute cleaned"

# Open services in browser
open-services:
	@echo "🌐 Opening Cilium Gateway API Demo services..."
	@echo "� Starting port forwarding first..."
	@$(MAKE) start-port-forwards
	@sleep 2
	@echo ""
	@echo "�📋 Checking service status..."
	@if curl -s http://localhost:8080/health > /dev/null; then \
		echo "✅ Demo App is running on port 8080"; \
	else \
		echo "❌ Demo App is not accessible on port 8080"; \
		echo "   Retrying in 3 seconds..."; \
		sleep 3; \
		if curl -s http://localhost:8080/health > /dev/null; then \
			echo "✅ Demo App is now running on port 8080"; \
		else \
			echo "❌ Demo App still not accessible. Check logs."; \
		fi; \
	fi
	@if curl -s http://localhost:12000 > /dev/null; then \
		echo "✅ Hubble UI is running on port 12000"; \
	else \
		echo "❌ Hubble UI is not accessible on port 12000"; \
		echo "   This is normal, Hubble UI might take longer to start"; \
	fi
	@echo ""
	@echo "🚀 Opening services in browser..."
	@if command -v open >/dev/null 2>&1; then \
		echo "Opening Demo App: http://localhost:8080"; \
		open -a "Google Chrome" http://localhost:8080; \
		sleep 1; \
		echo "Opening Hubble UI: http://localhost:12000"; \
		open -a "Google Chrome" http://localhost:12000; \
		echo ""; \
		echo "🎉 Both services opened in browser!"; \
		echo ""; \
		echo "💡 Tips:"; \
		echo "   - Refresh the Demo App page multiple times to see load balancing"; \
		echo "   - Check pod names and node assignments changing"; \
		echo "   - Use Hubble UI to monitor network traffic in real-time"; \
		echo "   - In Hubble UI, you can filter by namespace 'hello-world' to see your app traffic"; \
		echo "   - Run 'make stop-port-forwards' when you're done"; \
	else \
		echo "Browser auto-open not available. Please open manually:"; \
		echo "   Demo App: http://localhost:8080"; \
		echo "   Hubble UI: http://localhost:12000"; \
	fi

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
	@echo "📦 Application Pods:"
	@kubectl get pods -l app=hello-world -n hello-world 2>/dev/null || echo "   No application pods found"
	@echo ""
	@echo "🔗 Services:"
	@kubectl get service hello-world -n hello-world 2>/dev/null || echo "   No hello-world service found"

# Remove all resources and cluster
clean: cleanup-hello-world delete-cluster
	@echo "🧹 All resources and cluster removed!"

# Complete setup and deploy hello-world app
all: setup-infrastructure deploy-hello-world
	@echo "🎉 Complete setup finished and application deployed!"
