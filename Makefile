NAMESPACE := bugsink

.PHONY: deploy-local deploy-prod diff-local diff-prod \
status watch logs logs-follow logs-all logs-pod logs-postgres \
pvc hpa minikube-url teardown teardown-pvc

deploy-local:
	kubectl apply -k k8s/overlays/local/
	kubectl rollout restart deployment/bugsink -n bugsink

deploy-prod:
	kubectl apply -k k8s/overlays/production/

diff-local:
	kubectl diff -k k8s/overlays/local/

diff-prod:
	kubectl diff -k k8s/overlays/production/

status:
	kubectl get all -n $(NAMESPACE)

watch:
	kubectl get pods -n $(NAMESPACE) -w

logs:
	kubectl logs -n $(NAMESPACE) -l app=bugsink

logs-follow:
	kubectl logs -n $(NAMESPACE) -l app=bugsink -f

logs-all:
	kubectl logs -n $(NAMESPACE) -l app=bugsink --all-containers -f

logs-pod:
	kubectl logs -n $(NAMESPACE) $(POD)

logs-postgres:
	kubectl logs -n $(NAMESPACE) -l app=postgres -f

pvc:
	kubectl get pvc -n $(NAMESPACE)

hpa:
	kubectl get hpa -n $(NAMESPACE)

minikube-url:
	minikube service bugsink -n $(NAMESPACE) --url

teardown:
	kubectl delete namespace $(NAMESPACE)

teardown-pvc:
	kubectl delete pvc -n $(NAMESPACE) --all
