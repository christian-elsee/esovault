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

dist:
	: ## $@
	mkdir -p $@ $@/bin

	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* $@/bin/helm
	cp -rf helm $@
	envsubst <helm/vault.yaml | tee $@/helm/vault.yaml

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
		--values helm/vault.yaml

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
	kubectl exec vault-0 -- vault operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json \
  | tee dist/cluster-keys.json
