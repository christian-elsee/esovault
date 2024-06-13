# secrets-stack

Kubernetes orchestration workflow for external secrets operator and hosted hashicorp vault. Orchestration is encapsulated within a standard `make` workflow. All workflow targets ~~are~~ should be idempotent.

## dependencies

Basic development environment dependency/version pairs.

- gnu make, 4.4.1
```sh
$ make -v
GNU Make 4.4.1
Built for x86_64-apple-darwin22.3.0
Copyright (C) 1988-2023 Free Software Foundation, Inc.
License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
```

- gpg (GnuPG), 2.4.4
```sh
$ gpg --version
gpg (GnuPG) 2.4.4
libgcrypt 1.10.3
Copyright (C) 2024 g10 Code GmbH
License GNU GPL-3.0-or-later <https://gnu.org/licenses/gpl.html>
This is free software: you are free to change and redistribute it.
There is NO WARRANTY, to the extent permitted by law.
```

- kubectl, v1.29.2
```sh
 $ kubectl version
Client Version: v1.29.2
Kustomize Version: v5.0.4-0.20230601165947-6ce0bf390ce3
Server Version: v1.29.2
```

- helm, v3.14.2
```sh
$ helm version
version.BuildInfo{Version:"v3.14.2", GitCommit:"c309b6f0ff63856811846ce18f3bdc93d2b4d54b", GitTreeState:"clean", GoVersion:"go1.22.0"}
```

- rsync, v3.3.0
```sh
$ rsync --version | sed -n 1p
rsync  version 3.3.0  protocol version 31
```

- yq, v3.4.3
```sh
$ yq --version
yq 3.4.3
```

## install

Orchestrate esochart using `make` workflow. 

Build and validate chart artifacts against `dist/chart`.
```sh
$ make
: ## distclean
...
```

Install chart.  
```sh
$ make install
: ## install/vault
cd dist
helm upgrade vault hashicorp/vault \
  --install \
  --namespace vault \
  --create-namespace \
  --version 0.27.0 \
  --set='server.ha.enabled=true' \
  --set='server.ha.raft.enabled=true'
...
```

Stack components are defined as dependencies in `Chart.yaml`
```sh
$ cat Chart.yaml | sed -n '/dependencies/,$p'
dependencies:
  - name: vault
    repository: https://helm.releases.hashicorp.com
    version: 0.27.0
    alias: vault
  - name: external-secrets
    repository: https://charts.external-secrets.io
    version: 0.9.13
```
```sh
$ helm dependency list dist/chart -n secrets-stack
NAME              VERSION REPOSITORY                          STATUS
vault             0.27.0  https://helm.releases.hashicorp.com ok
external-secrets  0.9.13  https://charts.external-secrets.io  ok
```

```sh
$ make vault/init
: ## dist/unseal-key.txt
...
Success! You are now authenticated. The token information displayed below
is already stored in the token helper. You do NOT need to run "vault login"
```

Cluster keys are sealed/encrypted via gpg to `assets/cluster-keys.json.gpg`, alongside its detached signature, `assets/cluster-keys.json.sign`.
```sh
$ ls -lhat assets/cluster-keys.json.*
-rw-r--r-- 1 christian staff  566 Mar  7 13:00 assets/cluster-keys.json.sign
-rw-r--r-- 1 christian staff 1.2K Mar  7 10:58 assets/cluster-keys.json.gpg
```

Assets defined in `assets/*` are not commited. If either the signature or sealed key file is lost, you will need to tear down and rebuild the cluster. To reset the cluster to an initial state, run `make clean`, followed by `make` and `make install`.
```sh
$ make clean
: ## distclean
rm -rf dist
: ## clean
helm delete vault -n vault ||:
...
release "vault" uninstalled
```
```sh
$ make
...
```
```sh
$ make install
...
```

## License

[MIT](https://choosealicense.com/licenses/mit/)
