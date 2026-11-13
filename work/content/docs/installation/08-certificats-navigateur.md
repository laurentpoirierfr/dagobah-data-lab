---
title: "08 — Certificats TLS et import dans le navigateur"
weight: 9
---

> [!NOTE]
> Statut : ✅ installé · Date : 2026-11-11

## Objectif

Récupérer en fichiers les certificats émis par cert-manager dans k8s, et faire
approuver la CA locale par le navigateur pour tester `https://<app>.k8s.test`
sans alerte.

> ⚠️ **Pour les tests dans le navigateur, la CA locale doit être importée.**
> Sans elle, Firefox et Chrome affichent « La connexion n'est pas sécurisée »
> (`SEC_ERROR_UNKNOWN_ISSUER` / `NET::ERR_CERT_AUTHORITY_INVALID`) sur tous les
> sites `*.k8s.test`.
>
> Il faut importer **la CA** `certs/k8s-ca.crt`, et **non** le certificat du site
> (`certs/issued/<fqdn>/tls.crt`). Une fois la CA approuvée, tous les certificats
> qu'elle signe sont acceptés, y compris ceux émis plus tard.

## Prérequis

- [02 — Cluster minikube 3 nœuds](02-cluster-minikube.md) (cert-manager + ClusterIssuer `dagobah-ca-issuer`)

## Fichiers physiques depuis k8s

```bash
make cert HOST=podinfo      # certs/cert.sh export podinfo
make certs                  # tous les certificats signés par dagobah-ca-issuer
make ca                     # CA publique seule -> certs/k8s-ca.crt
```

```
certs/
├── cert.sh                       # script (seul fichier versionné)
├── k8s-ca.crt                    # CA publique  <- À IMPORTER DANS LE NAVIGATEUR
├── ca/{tls.crt,tls.key,ca.crt}   # sauvegarde de la CA (clé privée, 600)
└── issued/<fqdn>/
    ├── tls.crt                   # certificat du site
    ├── tls.key                   # clé privée (600)
    ├── ca.crt                    # CA
    └── fullchain.crt             # tls.crt + ca.crt
```

À chaque export, le script vérifie que la clé correspond au certificat et que la
chaîne remonte à la CA.

## Importer la CA dans le navigateur

### Méthode automatique

```bash
sudo apt install -y libnss3-tools     # fournit certutil (une fois)
certs/cert.sh trust                   # système (sudo) + Firefox + Chrome/Chromium
```

- **Magasin système** : `/usr/local/share/ca-certificates/k8s-local-ca-k8s.crt`
  et `update-ca-certificates` (pour curl, wget, Python, Go…).
- **Navigateurs (NSS)** : `~/.pki/nssdb` (Chrome/Chromium), le profil Firefox
  snap (`~/snap/firefox/common/.mozilla/firefox/*.default*`) et le profil Firefox
  classique.

Ensuite, **redémarrer le navigateur**.

### Firefox (manuel)

1. `Paramètres` → `Vie privée et sécurité` → section `Certificats` →
   `Afficher les certificats…`
2. Onglet `Autorités` → `Importer…` → choisir `~/Projects/dagobah-data-lab/certs/k8s-ca.crt`
3. Cocher **« Confirmer cette AC pour identifier des sites web »** → `OK`
4. Redémarrer Firefox

> Firefox snap : le sélecteur de fichiers ne voit pas toujours les dossiers
> cachés. Au besoin, copier d'abord la CA dans `~/Téléchargements/`.

### Chrome / Chromium (manuel)

1. Ouvrir `chrome://settings/certificates` (ou `Paramètres` → `Confidentialité et
   sécurité` → `Sécurité` → `Gérer les certificats`)
2. Onglet `Autorités` → `Importer` → `certs/k8s-ca.crt`
3. Cocher **« Faire confiance à ce certificat pour identifier les sites web »**
4. Redémarrer le navigateur

## Vérification

```bash
certs/cert.sh check podinfo                                 # Verify return code: 0 (ok)
curl --cacert certs/k8s-ca.crt https://podinfo.k8s.test/    # HTTP 200
```

Dans le navigateur : `https://podinfo.k8s.test` affiche le cadenas, et l'émetteur
indiqué est `dagobah-ca`.

## Pièges rencontrés

- **La CA change à chaque `make recreate`** : le lanceur la régénère. La CA
  importée dans le navigateur n'est alors plus reconnue et l'alerte revient.
  La CA est sauvegardée dans `certs/ca/`. Après une recréation :

  ```bash
  certs/cert.sh ca-restore     # réinstalle la CA sauvegardée + réémet les certificats
  certs/cert.sh ca-info        # empreinte sauvegarde == cluster
  ```

  (restauration pas encore testée après une vraie recréation). Sinon, réimporter
  la nouvelle `certs/k8s-ca.crt` dans le navigateur.
- Importer `tls.crt` (le certificat du site) au lieu de la CA ne fonctionne pas
  durablement : il faudrait recommencer à chaque renouvellement (tous les 90 jours).
- `certutil absent` : `sudo apt install libnss3-tools`, puis relancer `trust`.

## Désinstallation

```bash
certs/cert.sh untrust          # retire la CA du système et des navigateurs
```
