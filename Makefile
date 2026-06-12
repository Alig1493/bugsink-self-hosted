NAMESPACE := bugsink

.PHONY: deploy-local deploy-prod deploy-prod-traefik deploy-prod-cnpg \
diff-local diff-prod diff-prod-traefik diff-prod-cnpg \
render \
status watch logs logs-follow logs-all logs-pod logs-postgres \
restore-start restore-watch restore-cutover restore-cleanup \
pvc hpa minikube-url teardown teardown-pvc

deploy-local:
	kubectl apply -k k8s/overlays/local/
	kubectl rollout restart deployment/bugsink -n bugsink

deploy-prod:
	kubectl apply -k k8s/overlays/production/

deploy-prod-traefik:
	kubectl apply -k k8s/overlays/production-traefik/

deploy-prod-cnpg:
	kubectl apply -k k8s/overlays/production-cnpg/

diff-local:
	kubectl diff -k k8s/overlays/local/

diff-prod:
	kubectl diff -k k8s/overlays/production/

diff-prod-traefik:
	kubectl diff -k k8s/overlays/production-traefik/

diff-prod-cnpg:
	kubectl diff -k k8s/overlays/production-cnpg/

render:
	@bash scripts/render.sh

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

restore-start:
	kubectl apply -f k8s/overlays/production-cnpg/cluster-restore.yaml

restore-watch:
	kubectl get cluster -n $(NAMESPACE) -w

restore-cutover:
	kubectl delete cluster postgres -n $(NAMESPACE)

restore-cleanup:
	kubectl delete cluster postgres-restored -n $(NAMESPACE)

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
