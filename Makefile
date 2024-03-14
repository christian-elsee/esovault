.DEFAULT_GOAL := @goal
.SHELLFLAGS := -eu -o pipefail -c
.PHONY: build test run
.ONESHELL:
.DELETE_ON_ERROR:

## env
export NAME := $(shell basename $(PWD))
export PATH := ./bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## recipe
@goal: distclean dist build check
@chart/lockfile: distclean dist
	: ## $@
	rm -rf dist/chart/Chart.lock
	helm dependency update dist/chart

distclean:
	: ## $@
	rm -rf dist
clean: distclean
	: ## $@
	rm -rf assets/cluster-keys.json.*
	# delete helm charts in esovault
	helm uninstall $(NAME) \
		--cascade foreground \
		--wait \
		-n $(NAME) \
	||:

	# remove persistent volumes
	kubectl delete pvc --all -n $(NAME)  ||:
	kubectl delete pv --all -n $(NAME) ||:
	kubectl delete namespace $(NAME) ||:
	kubectl delete clustersecretstore vault ||:

dist:
	: ## $@
	mkdir -p $@ \
					 $@/bin \
					 $@/chart \
					 $@/chart/crds \
					 $@/chart/templates

	cp -rf src policy -- $@/
	cp Chart.* values.yaml -- $@/chart
	cp assets/helm-$(shell uname -s)-$(shell uname -m)-* \
		 $@/bin/helm

dist/ca.crt: dist
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
	| base64 -d >$@
dist/k8s-host.txt: dist
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster.server' \
	| base64 -d >$@
dist/unseal-keys.txt: dist assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| jq -re ".unseal_keys_b64[]" >$@
dist/root-token.txt: dist assets/cluster-keys.json.gpg
	: ## $@
	gpg --verify \
		assets/cluster-keys.json.sign \
		assets/cluster-keys.json.gpg

	<assets/cluster-keys.json.gpg gpg -d \
		| jq -re ".root_token" >$@
dist/auth-sa-token.txt: dist
	: ## $@
	kubectl -n eso get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d >$@
dist/build.checksum: dist
	: ## $@
	kubectl kustomize resources/crds \
		| tee dist/chart/crds/resources.yaml
	kubectl kustomize resources/templates \
		| tee dist/chart/templates/resources.yaml

	helm dependency build dist/chart
	find dist/chart \
		-type f \
    -exec md5sum {} + \
	| sort -k 2 \
	| md5sum \
	| cut -f1 -d" " \
	| tee dist/build.checksum
dist/chart/Chart.lock:
	: ## $@
	helm dependency update dist/chart

build: dist/build.checksum
	: ## $@
	cat dist/build.checksum

check: dist/chart
	: ## $@
	helm lint dist/chart --with-subcharts


install: install/chart \
		     vault/init
	: ## $@
	echo kubectl apply \
		-f dist/chart/crds/resources.yaml \
		-n $(NAME) \
		--timeout "60s"

install/chart: dist/build.checksum
	: ## $@
	helm upgrade $(NAME) dist/chart \
		--install \
		--skip-crds \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set sha="$(shell cat dist/build.checksum)"

vault/init: dist \
	          dist/root-token.txt \
						dist/ca.crt \
						dist/k8s-host.txt \
						dist/auth-sa-token.txt \
						vault/unseal
	: ## $@
	false
	cd dist
	src/vault.sh vault-0 login "$$(cat root-token.txt)"
	src/vault.sh vault-0 secrets enable -path=secret kv-v2 ||:
	src/vault.sh vault-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh vault-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$$(cat auth-sa-token.txt)" \
		kubernetes_host="$$(cat k8s-host.txt)" \
		kubernetes_ca_cert="$$(cat ca.crt)"
	src/vault.sh vault-0 write kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="eso" \
		policies="read_only" \
		ttl="15m"
	src/vault.sh vault-0 policy write read_only -<policy/read_only.hcl

assets/cluster-keys.json.gpg:
	: ## $@
	src/vault.sh vault-0 operator init \
    -key-shares=3 \
    -key-threshold=3 \
    -format=json \
  | gpg -aer $(NAME) \
  | tee assets/cluster-keys.json.gpg

	gpg -u $(shell basename $(PWD)) \
			--output assets/cluster-keys.json.sign \
			--detach-sig assets/cluster-keys.json.gpg

vault/unseal: dist dist/unseal-keys.txt
	: ## $@
	cd dist

	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	src/vault.sh vault-1 operator raft join \
		http://vault-0.vault-internal:8200
	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	src/vault.sh vault-2 operator raft join \
		http://vault-0.vault-internal:8200
	<unseal-keys.txt xargs -n1 -- src/vault.sh vault-0 operator unseal

	kubectl get pods -n vault
	src/vault.sh vault-0 status

vault/seal:
	: ## $@
	src/vault.sh vault-0 operator seal
