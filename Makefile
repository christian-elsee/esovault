.DEFAULT_GOAL := all
.SHELLFLAGS := -euo pipefail $(if $(TRACE),-x,) -c
.ONESHELL:
.DELETE_ON_ERROR:
.PHONY: all \
				build \
				check \
				install \
				test \
				chart/* \
				vault/* \
				install/*

## env ##########################################
export NAME := $(shell basename $(PWD))
export PATH := dist/bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## interface ####################################
all: distclean dist build check
install: install/crds install/chart vault/init  artifacts/vault
clean:
test:
status:
vault/unseal:
vault/seal:

## clean ########################################
distclean:
	: ## $@
	rm -rf dist
clean:
	: ## $@
	helm delete --cascade=foreground -n $(NAME) $(NAME) ||:
	kubectl delete namespace $(NAME) --wait --cascade=foreground ||:
	kubectl delete namespace $(NAME)-test --wait --cascade=foreground ||:
	kubectl delete clustersecretstore all ||:
	kubectl delete clusterexternalsecret all ||:
	kubectl delete -f dist/chart/crds

## dist #########################################
dist:
	: ## $@
	mkdir -p $@/.     \
					 $@/bin   \
					 $@/store \
					 $@/artifacts

	# cp needed artifacts to build chart dist
	cp -rf policy $@/

	# cp chart directory structure, dependency files, values files and any
	# existing artifacts
	find chart -type d -print0 \
		| tac -s "" \
		| xargs -0I% -- mkdir -p "$@/%"
	cp -f chart/Chart.* chart/values.yaml $@/chart

	# cp helm bin from assets, using os and cpu arch as keys
	tar -tf assets/helm-$(shell uname -s)-$(shell uname -m)-* \
		| sed -n 1p \
		| xargs -I% -- \
			tar -xv \
					-f assets/helm-$(shell uname -s)-$(shell uname -m)-* \
					-C dist/bin \
					--strip-components=1 \
					%/helm

dist/store/cacrt:
	: ## $@
	yq -re <$(KUBECONFIG) \
		'.clusters[0].cluster."certificate-authority-data"' \
		| base64 -d \
		| gpg -aer $(NAME) 
		| tee $@
dist/store/KUBE_SERVER:
	: ## $@
	yq -re <$(KUBECONFIG) \
		".clusters[0].cluster.server" \
		| gpg -aer $(NAME) 
		| tee $@		
dist/store/unseal_keys: dist/artifacts/vault
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< \
		| jq -re ".unseal_keys_b64[]" \
		| xargs \
		| gpg -aer $(NAME) 
		| tee $@		
dist/store/VAULT_TOKEN: dist/artifacts/vault
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< \
		| jq -re ".root_token" \
		| gpg -aer $(NAME) 
		| tee $@	
dist/store/auth_sa_token:
	: ## $@
	kubectl -n $(NAME) get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d \
		| gpg -aer $(NAME) 
		| tee $@		
dist/store/vault: dist/store/checksum
	: ## $@
	# init vault leader, encrypt keys and write to disk
	src/vault.sh $(NAME)-0 operator init \
    -key-shares=3 \
    -key-threshold=3 \
    -format=json \
  | gpg -aer $(NAME) \
  | tee $@
	# sign encrypted keys
	gpg -u $(shell basename $(PWD)) \
			--output $@.sign \
			--detach-sig $@
	# publish keys/sig tar pair to artifacts w/appended checksum
	tar -cvf $@.tar.$(shell cat dist/store/checksum) $@ $@.sign -C artifacts 
dist/store/digest: chart/Chart.lock
	: ## $@
	# cp cached chart dependencies, from assets, if they exist, using
	# chart.lock digest as a hash key	
	<chart/Chart.lock yq -re ".digest" \
		| sed -En 's/sha256://p' \
		| tee $@ \
		| xargs -rI% -- cp -rf assets/charts.% dist/chart/charts \
	||:

dist/checksum:
	: # $@
	# publish determinitive checksum to artifacts
	find chart \
		-type f \
    -exec md5sum {} + \
		| sort -k 2 \
		| md5sum \
		| cut -f1 -d" " \
		| tee $@ >>dist/artifacts/log

dist/chart/charts: dist/chart dist/store/digest
	: ## $@
	# build chart dependencies
	helm dep update dist/chart \
		--skip-refresh \
		--debug \
	| tee -a dist/artifacts/log
	rsync -av --delete $@/ assets/charts.$(shell cat dist/store/digest)

dist/chart/templates/resources.yaml: chart/templates
	: ## $@
	# generate local chart templated resources manifest
	kubectl kustomize chart/templates \
		| tee $@ >>dist/artifacts/log

dist/artifacts/manifest.yaml: dist/chart dist/checksum
	: ## $@
	# render chart templates manifest to artifacts
	helm template $(NAME) dist/chart \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" \
		--dry-run=client \
	| tee $@ >>dist/artifacts/log

dist/chart/crds/resources.yaml: dist/artifacts/manifest.yaml
	: ## $@
	<$< yq --yaml-output \
				'select(.kind == "CustomResourceDefinition")' \
	| tee $@ >>dist/artifacts/log

build: dist/checksum \
			 dist/store/digest \
			 dist/chart/charts \
			 dist/chart/templates/resources.yaml \
			 dist/artifacts/manifest.yaml \
			 dist/chart/crds/resources.yaml
build:
	: # $@
	cat dist/checksum

check: dist/chart dist/chart/crds/resources.yaml dist/checksum
	: ## $@
	# perform a client side dry run of helm install process as a santiy
	# check of helm workflow against the generated chart resources
	kubectl apply \
		--dry-run=client \
		-f dist/chart/crds/resources.yaml \
	| tee dist/artifacts/log

	helm lint dist/chart \
		--debug \
		--with-subcharts \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" \
 	| tee dist/artifacts/log


## install ######################################
install/crds: dist/chart/crds/resources.yaml
	: ## $@
	kubectl apply -f $<

install/chart: dist/chart dist/checksum
	: ## $@
	helm upgrade $(NAME) dist/chart \
		--install \
		--wait \
		--skip-crds \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" 

## vault ########################################
vault/init: dist/VAULT_TOKEN \
						dist/cacrt \
						dist/KUBE_SERVER \
						dist/auth_sa_token \
						vault/unseal
	: ## $@
	src/vault.sh $(NAME)-0 login "$(shell cat dist/env/VAULT_TOKEN)"
	src/vault.sh $(NAME)-0 secrets enable -path=secret -version=1 kv ||:
	src/vault.sh $(NAME)-0 policy write read_only -<dist/policy/read_only.json
	src/vault.sh $(NAME)-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$(shell cat dist/env/auth_sa_token)" \
		kubernetes_host="$(shell cat dist/env/KUBE_SERVER)" \
		kubernetes_ca_cert="$$(cat dist/env/cacrt)" # this has to process subs to account for newlines
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="$(NAME)" \
		policies="read_only" \
		ttl="15m"
	src/vault.sh $(NAME)-0 kv get secret/init \
		|| src/vault.sh $(NAME)-0 kv put \
				secret/init \
					checksum=$(shell cat dist/checksum)

vault/unseal: dist/unseal_keys
	: ## $@
	xargs -n1 src/vault.sh $(NAME)-0 operator unseal <dist/env/unseal_keys

	src/vault.sh $(NAME)-1 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	xargs -n1 src/vault.sh $(NAME)-1 operator unseal <dist/env/unseal_keys

	src/vault.sh $(NAME)-2 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	xargs -n1 src/vault.sh $(NAME)-2 operator unseal <dist/env/unseal_keys

	src/vault.sh $(NAME)-0 status
	src/vault.sh $(NAME)-1 status
	src/vault.sh $(NAME)-2 status
	kubectl get pods -n $(NAME)

vault/seal:
	: ## $@
	src/vault.sh $(NAME)-0 operator seal

## test #########################################
test: distclean dist build
	: ## $@
	rsync -avh --delete t/ dist/t/

	# cd dist && prove -vr
	helm test $(NAME) -n $(NAME)

## status #######################################
status:
	: ## $@
	helm status $(NAME) -n $(NAME) --show-resources

