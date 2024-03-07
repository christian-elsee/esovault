.DEFAULT_GOAL := @goal

.ONESHELL:
.POSIX:
.DELETE_ON_ERROR:
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
	- helm delete vault -n vault
	- helm delete external-secrets -n external-secrets
	- kubectl delete pvc --all -n vault
	- kubectl delete pv --all -n vault
	- kubectl delete namespace vault
	- kubectl delete namespace external-secrets
	- rm -rf assets/cluster-keys.json.*

dist:
	: ## $@
	mkdir -p $@ $@/bin
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* $@/bin/helm
	cp -rf src $@/

dist/unseal-key.txt: dist
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| jq -re ".unseal_keys_b64[]" >$@

dist/root-token.txt: dist
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| tee $@/cluster-keys.json \
		| jq -re ".root_token" >$@

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
	kubectl -n vault get all

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
	kubectl -n external-secrets get all

vault/init: dist
vault/init: assets/cluster-keys.json.gpg dist/root-token.txt
vault/init: vault/unseal
	: ## $@
	cd dist
	src/vault.sh vault-0 login "$$(cat root-token.txt)"
	- src/vault.sh vault-0 secrets enable -path=secret kv-v2
	- src/vault.sh vault-0 auth enable kubernetes

assets/cluster-keys.json.gpg:
	: ## $@
	src/vault.sh vault-0 operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json \
  | gpg -aer esovault \
  | tee assets/cluster-keys.json.gpg

	gpg -u $(shell basename $(PWD)) \
			--output assets/cluster-keys.json.sign \
			--detach-sig assets/cluster-keys.json.gpg

vault/unseal: dist dist/unseal-key.txt
	: ## $@
	cd dist

	src/vault.sh vault-0 operator unseal "$$(cat unseal-key.txt)"
	src/vault.sh vault-1 operator raft join \
		http://vault-0.vault-internal:8200
	src/vault.sh vault-1 operator unseal "$$(cat unseal-key.txt)"
	src/vault.sh vault-2 operator raft join \
		http://vault-0.vault-internal:8200
	src/vault.sh vault-2 operator unseal "$$(cat unseal-key.txt)"

	kubectl get pods -n vault
	src/vault.sh vault-0 status

vault/seal:
	: ## $@
	src/vault.sh vault-0 operator seal
