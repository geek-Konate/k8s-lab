# Laboratoire DevSecOps — Vagrant, Ansible, k3s, Podman et Trivy

Laboratoire pratique de déploiement Kubernetes sur machines virtuelles Ubuntu 24.04, avec construction d'une image Nginx non-root, scan des vulnérabilités et blocage du déploiement en présence de vulnérabilités **HIGH** ou **CRITICAL**.

## Architecture

| Machine | Adresse IP | Ressources | Rôle |
|---|---|---|---|
| Hôte Kali Linux | — | 16 Go de RAM physique | Vagrant / VirtualBox / navigateur |
| `control` | `192.168.56.10` | 3–4 Go RAM, 2 vCPU | Ansible, Podman, Trivy, Git |
| `k8s` | `192.168.56.20` | 6 Go RAM, 2 vCPU | Cluster k3s à nœud unique, containerd, Nginx |
| `monitoring` | `192.168.56.30` | 2 Go RAM, 2 vCPU | Réservée à un futur laboratoire ; non requise ici |

> Les deux pods Nginx tournent **sur le même nœud** : cela n'offre pas de haute disponibilité si la VM k8s s'arrête.

## Structure du projet

```text
k8s-lab/
├── inventory.ini
├── install_k3s.yml
├── deploy_app.yml
├── Dockerfile
├── k8s/
│   └── app.yaml
├── reports/
│   ├── trivy-nginx.txt
│   ├── trivy-nginx-new.txt
│   └── trivy-nginx-patched.txt
├── .gitignore
└── README.md
```

Les archives `.tar` d'images sont exclues de Git par `.gitignore`.

## Préparer l'environnement

Depuis Kali Linux, dans le dossier contenant le `Vagrantfile` :

```bash
vagrant up control k8s
vagrant status
vagrant ssh control
```

Sur `control`, installer Ansible, Podman, Git et Trivy (selon leur documentation officielle), puis vérifier :

```bash
ansible --version
podman --version
trivy --version
git --version
ping -c 4 192.168.56.20
```

Configurer un accès SSH par clé de `control` vers `k8s` pour l'utilisateur `vagrant`. L'inventaire utilisé dans ce laboratoire est :

```ini
[k3s]
192.168.56.20 ansible_user=vagrant ansible_ssh_private_key_file=/home/vagrant/.ssh/id_ed25519
```

Tester la connectivité Ansible :

```bash
cd ~/k8s-lab
ansible -i inventory.ini k3s -m ping
```

Résultat attendu : `SUCCESS`, `ping: pong`.

## Installer Kubernetes

```bash
ansible-playbook -i inventory.ini install_k3s.yml --syntax-check
ansible-playbook -i inventory.ini install_k3s.yml
ansible -i inventory.ini k3s -b -a '/usr/local/bin/k3s kubectl get nodes'
```

Résultat observé lors du laboratoire : nœud `k8s`, statut `Ready`, version `v1.37.2+k3s1`.

## Construire, scanner et déployer Nginx

Le fichier `Dockerfile` utilise une image Nginx non-root basée sur Alpine, applique une mise à jour des packages disponibles (`apk upgrade --no-cache`), puis revient à l'utilisateur non privilégié `101:101`.

Le manifeste `k8s/app.yaml` doit référencer :

```yaml
image: localhost/nginx-secure:patched-1
imagePullPolicy: Never
```

Il conserve **2 replicas**, les contrôles de sécurité (`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]`, `seccompProfile: RuntimeDefault`), les probes, le volume temporaire `/tmp` et le Service NodePort `30080`.

Lancer la chaîne automatisée :

```bash
ansible-playbook -i inventory.ini deploy_app.yml --syntax-check
ansible-playbook -i inventory.ini deploy_app.yml
```

Le playbook : construit l'image avec Podman, supprime l'ancienne archive, exporte l'image, la scanne avec Trivy, arrête le pipeline si HIGH/CRITICAL sont détectées, copie l'image sur `k8s`, l'importe dans le namespace containerd `k8s.io`, applique le manifeste, redémarre le déploiement et teste HTTP.

## Vérification fonctionnelle

```bash
ansible -i inventory.ini k3s -b -a '/usr/local/bin/k3s kubectl get pods -o wide'
ansible -i inventory.ini k3s -b -a '/usr/local/bin/k3s kubectl get deploy web -o wide'
curl -I http://192.168.56.20:30080
```

Résultats observés : **2 pods Running (1/1)**, **0 redémarrage**, réponse **HTTP 200 OK** sur `192.168.56.20:30080`.

## Résultats des scans Trivy

| Image | HIGH | CRITICAL | Total HIGH/CRITICAL |
|---|---:|---:|---:|
| `nginxinc/nginx-unprivileged:1.31.7-alpine3.24` | 12 | 1 | 13 |
| `nginxinc/nginx-unprivileged:mainline-alpine` | 12 | 1 | 13 |
| `localhost/nginx-secure:patched-1` après correctifs Alpine | 0 | 0 | 0 |

Les rapports sont conservés dans `reports/`. Le dernier résultat **0** concerne uniquement les vulnérabilités connues de sévérité HIGH et CRITICAL au moment de l'analyse. Il ne signifie pas absence totale de risques, et doit être régulièrement réévalué.

Exécuter un contrôle manuel :

```bash
trivy image --input reports/nginx-secure-patched.tar \
  --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
  --format table --output reports/trivy-nginx-patched.txt
```

## Erreurs rencontrées et solutions

| Erreur | Cause | Correctif |
|---|---|---|
| `UNREACHABLE` via Ansible | Chemin de clé SSH erroné (`id_ed255119`) | Utiliser `id_ed25519` |
| `imagePullPolicy: Unsupported value: "never"` | Valeur sensible à la casse | `Never` |
| Trivy : archive introuvable | Archive Podman non encore exportée | Construire puis `podman save` |
| `docker-archive doesn't support modifying existing images` | Archive déjà existante | Supprimer l'ancienne archive avant export |

## Limites et améliorations futures

- Cluster **à nœud unique** : pas de haute disponibilité d'infrastructure.
- Accès HTTP **sans TLS**, réservé au réseau privé du lab.
- Images chargées localement, pas de registre OCI/CI/CD distant.
- Tag d'image `patched-1` **mutable** ; utiliser un digest immuable pour un contexte de production.
- Le Dockerfile dépend des mises à jour disponibles au moment du build ; fixer la base, documenter les versions, scanner régulièrement.
- Étapes suivantes : contrôle RBAC, NetworkPolicy (avec politique réseau prise en charge), CI/CD, secrets chiffrés, Prometheus et Grafana.

## Publication GitHub

Ne pas versionner les archives `.tar`, les clés SSH privées, les secrets et les fichiers `.env`.

```bash
git init
git add .
git status
git commit -m 'feat: automate secure k3s nginx deployment with trivy gate'
git branch -M main
# Créer d'abord un dépôt GitHub vide, puis :
git remote add origin https://github.com/TON_COMPTE/k8s-lab.git
git push -u origin main
```

Ce laboratoire est une démonstration pédagogique : les résultats décrivent les tests effectivement observés, et le pipeline complet doit être retesté après toute modification.
