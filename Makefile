.DEFAULT_GOAL := @goal

.ONESHELL:
.POSIX:
.PHONY: build test run

## env
export PATH := ./bin:$(PATH)


## recipe
@goal: distclean dist init check

distclean:
	: ## $@
	rm -rf dist
clean: distclean
	: ## $@
	cd dist
	helm delete vault -n vault
	helm delete external-secrets -n external-secrets
	kubectl delete pvc --all -n vault
	kubectl delete pv --all -n vault

dist:
	: ## $@
	mkdir -p $@ $@/bin

	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* $@/bin/helm
	cp -rf helm $@
	<helm/vault.yaml envsubst | tee $@/helm/vault.yaml

	<assets/cluster-keys.json.gpg gpg -d \
		| tee $@/cluster-keys.json \
		| jq -re ".unseal_keys_b64[]" \
		| tee $@/unseal-key.txt >/dev/null \
	||:

init:
init:
	: ## $@
	cd dist

	helm repo update
	helm  search repo hashicorp/vault
	helm repo add hashicorp https://helm.releases.hashicorp.com

	helm search repo external-secrets/external-secrets
	helm repo add external-secrets https://charts.external-secrets.io

check:
	: ## $@

install: dist install/vault install/eso
	: ## $@

install/vault: version := 0.27.0
install/vault:
	: ## $@
	cd dist
	helm upgrade vault hashicorp/vault \
		--install \
		--namespace vault \
		--create-namespace \
		--version $(version) \
		--set='server.ha.enabled=true' \
  	--set='server.ha.raft.enabled=true'

install/eso: version := 0.9.13
install/eso: dist
	: ## $@
	cd dist
	helm upgrade external-secrets external-secrets/external-secrets \
		--install \
  	--namespace external-secrets \
  	--create-namespace \
  	--version $(version) \
		--set installCRDs=true

vault/keys: dist
	: ## $@
	cd dist
	kubectl -n vault exec vault-0 -- vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json \
  >cluster-keys.json

vault/unseal: dist
	: ## $@
	cd dist

	kubectl -n vault exec vault-0 -- \
		vault operator unseal "$$(cat unseal-key.txt)"

	kubectl -n vault exec -it vault-1 -- \
		vault operator raft join http://vault-0.vault-internal:8200
	kubectl -n vault exec -it vault-1 -- \
		vault operator unseal "$$(cat unseal-key.txt)"

	kubectl -n vault exec -it vault-2 -- \
		vault operator raft join http://vault-0.vault-internal:8200
	kubectl -n vault exec -it vault-2 -- \
		vault operator unseal "$$(cat unseal-key.txt)"

	kubectl get pods -n vault

