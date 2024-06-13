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
export NS := $(NAME)
export PATH := dist/bin:$(PATH)
export KUBECONFIG ?= $(HOME)/.kube/config

## interface ####################################
all: distclean dist build check 
install: install/crds \
				 install/chart \
				 vault/bootstrap \
				 dist/artifacts/manifest.gpg \
				 dist/artifacts/values.gpg
test: testclean \
			test/volumes \
	    dist/chart/templates/tests/resources.yaml \
		  check \
			install/crds \
			install/chart 
status:
clean:
vault/unseal:
vault/seal:

## clean ########################################
distclean:
	: ## $@
	rm -rf dist
clean:
	: ## $@
	helm delete $(NAME) \
		-n $(NAME) \
		--debug \
		--no-hooks \
		--ignore-not-found \
		--cascade=foreground \
	||:
	kubectl delete namespace $(NAME) --wait --cascade=foreground ||:
	kubectl delete namespace $(NAME)-test --wait --cascade=foreground ||:
	kubectl delete clustersecretstore all ||:
	kubectl delete clusterexternalsecret all ||:
	kubectl delete -f dist/chart/crds ||:

## dist #########################################
dist:
	: ## $@
	mkdir -p $@/.     \
					 $@/bin   \
					 $@/store \
					 $@/artifacts

	# cp needed artifacts to build/test chart dist
	cp -rf policy $@/

	# cp chart directory structure, dependency and values files
	# to dist/chart
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
		| gpg -aer $(NAME) \
		| tee $@
dist/store/KUBE_SERVER:
	: ## $@
	yq -re <$(KUBECONFIG) \
		".clusters[0].cluster.server" \
		| gpg -aer $(NAME) \
		| tee $@		
dist/store/unseal_keys: dist/artifacts/vault-bootstrap.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< \
		| jq -re ".unseal_keys_b64[]" \
		| xargs \
		| gpg -aer $(NAME) \
		| tee $@		
dist/store/VAULT_TOKEN: dist/artifacts/vault-bootstrap.gpg
	: ## $@
	gpg --verify $<.sign $<
	gpg -d <$< \
		| jq -re ".root_token" \
		| gpg -aer $(NAME) \
		| tee $@	
dist/store/auth_sa_token:
	: ## $@
	kubectl -n $(NAME) get secret auth-sa-token -ojson \
		| jq -re ".data.token" \
		| base64 -d \
		| gpg -aer $(NAME) \
		| tee $@		
dist/artifacts/vault-bootstrap.gpg: dist/checksum
	: ## $@
	# init vault leader, encrypt keys and write to disk
	src/vault.sh $(NAME)-0 operator init \
    -key-shares=1 \
    -key-threshold=1 \
    -format=json \
  | gpg -aer $(NAME) \
  | tee $@
	# sign encrypted keys
	gpg -u $(shell basename $(PWD)) \
			--output $@.sign \
			--detach-sig $@
	# publish keys/sig tar pair to assets w/appended checksum
	tar -cv \
			-C dist/artifacts \
			-f assets/$(notdir $@).tar.$(shell cat $<) \
			-- $(notdir $@) $(notdir $@).sign 
dist/store/digest: chart/Chart.lock
	: ## $@
	# cp cached chart dependencies, from assets, if they exist, using
	# chart.lock digest as a hash key	
	<$< yq -re ".digest" \
		| sed -En 's/sha256://p' \
		| tee $@ \
		| xargs -rI% -- cp -rf assets/charts.% dist/chart/charts \
	||:

dist/checksum:
	: # $@
	# publish determinitive checksum to artifacts
	find chart policy \
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
	kubectl kustomize $< \
		| tee $@ >>dist/artifacts/log

dist/chart/templates/tests/resources.yaml: chart/templates/tests
	: ## $@
	# generate local chart templated resources manifest
	kubectl kustomize $< \
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

dist/artifacts/manifest.gpg: 
	: ## $@
	# render installed resources to encrypted file to use as a debug and cleanup resource
	helm get manifest $(NAME) -n $(NAME) \
		| gpg -aer $(NAME) \
	>>$@ 
dist/artifacts/values.gpg: 
	: ## $@
	# render installed resources to encrypted file to use as a debug and cleanup resource
	helm get values $(NAME) -n $(NAME) \
		| gpg -aer $(NAME) \
	>>$@ 

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
		--dry-run=server \
		-f dist/chart/crds/resources.yaml \
	| tee -a dist/artifacts/log

	kubectl apply \
		--dry-run=client \
		-f dist/chart/crds/resources.yaml \
	| tee -a dist/artifacts/log

	helm lint dist/chart \
		--debug \
		--with-subcharts \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" \
 	| tee -a dist/artifacts/log


## install ######################################
install:
	: ## @

install/crds: dist/chart/crds/resources.yaml
	: ## $@
	kubectl apply -f $< --server-side

install/chart: dist/chart dist/checksum
	: ## $@
	helm upgrade $(NAME) dist/chart \
		--install \
		--wait \
		--skip-crds \
		--debug \
		--dependency-update \
		--render-subchart-notes \
		--create-namespace \
		--namespace "$(NAME)" \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" \
		--set "eso.installCRDs=false" \
		--set "vault.installCRDs=false" \
	| tee -a dist/artifacts/log

## vault ########################################
vault/bootstrap:	dist/artifacts/vault-bootstrap.gpg \
	          		 	dist/store/VAULT_TOKEN \
									dist/store/cacrt \
									dist/store/KUBE_SERVER \
									dist/store/auth_sa_token \
									vault/unseal
	: ## $@
	src/vault.sh $(NAME)-0 login "$(shell gpg -d <dist/store/VAULT_TOKEN)"
	src/vault.sh $(NAME)-0 secrets enable -path=secret -version=1 kv ||:
	src/vault.sh $(NAME)-0 policy write read_only -<dist/policy/read_only.json
	src/vault.sh $(NAME)-0 auth enable -path=kubernetes/internal kubernetes ||:
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/config \
		token_reviewer_jwt="$(shell gpg -d <dist/store/auth_sa_token)" \
		kubernetes_host="$(shell gpg -d <dist/store/KUBE_SERVER)" \
		kubernetes_ca_cert="$$(gpg -d <dist/store/cacrt)" # this has to process subs to account for newlines
	src/vault.sh $(NAME)-0 write auth/kubernetes/internal/role/eso-creds-reader \
		bound_service_account_names="auth-sa" \
		bound_service_account_namespaces="$(NAME)" \
		policies="read_only" \
		ttl="15m"
	src/vault.sh $(NAME)-0 kv get secret/init \
		|| src/vault.sh $(NAME)-0 kv put \
				secret/init \
					checksum=$(shell cat dist/checksum)

vault/unseal: dist/store/unseal_keys
	: ## $@
	# unseal leader
	gpg -d <dist/store/unseal_keys \
		| xargs -n1 src/vault.sh $(NAME)-0 operator unseal

	# signal join $vault-1 to leader and unseal
	src/vault.sh $(NAME)-1 operator raft join http://$(NAME)-0.$(NAME)-internal:8200	
	gpg -d <dist/store/unseal_keys \
		| xargs -n1 src/vault.sh $(NAME)-1 operator unseal

	# signal join $vault-2 to leader and unseal
	src/vault.sh $(NAME)-2 operator raft join \
		http://$(NAME)-0.$(NAME)-internal:8200
	gpg -d <dist/store/unseal_keys \
		| xargs -n1 src/vault.sh $(NAME)-2 operator unseal 

	# get status for each cluster node
	seq 0 2 \
		| xargs -I% -- src/vault.sh $(NAME)-% status \
		| tee -a dist/artifacts/log
	kubectl get pods -n $(NAME) \
		| tee -a dist/artifacts/log

vault/seal:
	: ## $@
	src/vault.sh $(NAME)-0 operator seal

## test #########################################
test:
	: ## $@
	helm test $(NAME) -n $(NAME) --debug \
		| tee -a dist/artifacts/logs

test/volumes:
	: ## $@
	# create configmap volumes needed to mount tap tests and runner

testclean: 
	: ## $@
	# Remove test artifacts to ensure baseline state, tabula rasa, etc
	helm template dist/chart \
		--show-only templates/tests/resources.yaml \
		--set "name=$(NAME)" \
		--set "checksum=$(shell cat dist/checksum)" \
	| kubectl delete \
			-f- \
			--ignore-not-found=true \
	||:
	rm -f dist/chart/templates/tests/resources.yaml

## status #######################################
status:
	: ## $@
	helm status $(NAME) -n $(NAME) --show-resources

