# ChaoStock 4-Pod EKS demo; see the workbook's STEP 6-9.
.DEFAULT_GOAL := help
TEAM ?= 5
NS := container-$(TEAM)
ENV ?= eks
TAG ?= 1.0.0
GHCR_OWNER ?= container-team5-chaos
MINIKUBE_PROFILE ?= chaos-lab
EKS_CONTEXT ?= container-5
ALB ?= k8s-sbgdemo-efa2aa8cf7-2001705629.ap-northeast-2.elb.amazonaws.com
CHART := deploy/eks
ORDER_IMAGE := ghcr.io/$(GHCR_OWNER)/chaostock-order
PUSH_IMAGE := ghcr.io/$(GHCR_OWNER)/chaostock-push-server

ifeq ($(ENV),eks)
CONTEXT := $(EKS_CONTEXT)
HELM_FLAGS := -f $(CHART)/values-eks.yaml --set-string images.order.repository=$(ORDER_IMAGE) --set-string images.push.repository=$(PUSH_IMAGE) --set-string images.order.tag=$(TAG) --set-string images.push.tag=$(TAG)
else ifeq ($(ENV),local)
CONTEXT := $(MINIKUBE_PROFILE)
HELM_FLAGS := --set ingress.enabled=false
else
$(error ENV must be eks or local)
endif

.PHONY: help build load push lint template preflight dryrun deploy test status history rollback clean

help:
	@echo 'make build/load ENV=local | make push TAG=1.0.0 | make lint/template/preflight/dryrun/deploy/test/status/history ENV=eks TAG=1.0.0 | make rollback ENV=eks'

build:
	docker build --platform linux/arm64 -f workloads/order/Dockerfile -t ghcr.io/container-team5-chaos/chaostock-order:eks-v1 workloads/order
	docker build --platform linux/arm64 -f workloads/push-server/Dockerfile -t ghcr.io/container-team5-chaos/chaostock-push-server:eks-v1 workloads/push-server

load:
	minikube -p $(MINIKUBE_PROFILE) image load ghcr.io/container-team5-chaos/chaostock-order:eks-v1
	minikube -p $(MINIKUBE_PROFILE) image load ghcr.io/container-team5-chaos/chaostock-push-server:eks-v1

push:
	docker buildx build --platform linux/amd64 --label org.opencontainers.image.source=https://github.com/Container-team5-chaos/ChaoStock -f workloads/order/Dockerfile -t $(ORDER_IMAGE):$(TAG) --push workloads/order
	docker buildx build --platform linux/amd64 --label org.opencontainers.image.source=https://github.com/Container-team5-chaos/ChaoStock -f workloads/push-server/Dockerfile -t $(PUSH_IMAGE):$(TAG) --push workloads/push-server

lint:
	helm lint $(CHART) $(HELM_FLAGS)

template:
	helm template app $(CHART) --namespace $(NS) $(HELM_FLAGS)

preflight:
	TEAM=$(TEAM) CONTEXT=$(CONTEXT) bash scripts/eks-preflight.sh

dryrun:
	helm template app $(CHART) --namespace $(NS) $(HELM_FLAGS) | kubectl --context $(CONTEXT) -n $(NS) apply --dry-run=server -f -

deploy:
	@test "$(ENV)" = "eks" || { echo 'This target is EKS-only; local Helm already uses a different release.'; exit 1; }
	kubectl --context $(CONTEXT) -n $(NS) get secret chaostock-db -o name
	helm upgrade --install app $(CHART) --kube-context $(CONTEXT) --namespace $(NS) $(HELM_FLAGS) --wait --timeout 10m

test:
ifeq ($(ENV),eks)
	curl -fsS --max-time 15 -o /dev/null -w 'Health HTTP %{http_code}\n' http://$(ALB)/$(NS)/health
	curl -fsS --max-time 15 -o /dev/null -w 'Web HTTP %{http_code}\n' http://$(ALB)/$(NS)/
	curl -fsS --max-time 15 http://$(ALB)/$(NS)/api/accounts/user-0001/positions
else
	curl -fsS --max-time 15 -o /dev/null -w 'Health HTTP %{http_code}\n' http://localhost:18080/$(NS)/health
endif

status:
	kubectl --context $(CONTEXT) -n $(NS) get pods,svc,ingress,pvc
	kubectl --context $(CONTEXT) -n $(NS) describe resourcequota team-quota

history:
	helm history app --kube-context $(CONTEXT) -n $(NS)

rollback:
	@test "$(ENV)" = "eks" || { echo 'EKS only'; exit 1; }
	helm rollback app --kube-context $(CONTEXT) -n $(NS) --wait --timeout 10m

clean:
	@test "$(CONFIRM)" = "DELETE" || { echo 'Refusing removal. Use CONFIRM=DELETE after reviewing consequences; PVC may remain.'; exit 1; }
	helm uninstall app --kube-context $(CONTEXT) -n $(NS)
