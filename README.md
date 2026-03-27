# 🛡️ Facebook Blocker & Monitor

Reprenez le contrôle de votre productivité. Ce projet propose des scripts Bash légers pour bloquer Facebook ou limiter votre temps d'utilisation quotidien en modifiant intelligemment votre fichier `/etc/hosts`.

## ✨ Fonctionnalités

* **Blocage Instantané :** Bloquez l'accès à Facebook d'une seule commande.
* **Gestion du Temps (Nouveau) :** Utilisez le mode `watch` pour définir une limite de temps quotidienne (ex: 3 heures).
* **Ciblage par Domaine :** Supporte `facebook.com` et ses sous-domaines.
* **Installation Facile :** Pas de dépendances lourdes, juste du pur Bash.

## ⚙️ Installation

1.  **Clonez le dépôt :**
    ```bash
    git clone https://github.com/votre-utilisateur/facebook-blocker.git
    cd facebook-blocker
    ```

2.  **Rendez les scripts exécutables :**
    ```bash
    chmod +x block_fb.sh timelimit.sh
    ```

## 🚀 Utilisation

> [!IMPORTANT]
> Ces scripts nécessitent des privilèges **root** (sudo) car ils modifient le fichier système `/etc/hosts`.

### 1. Blocage manuel
Pour activer ou désactiver manuellement le blocage :
```bash
sudo ./block_fb.sh block
sudo ./block_fb.sh unblock
```

### 2. Limite de temps automatique (Mode Watch)
Pour surveiller votre temps passé sur un domaine et le bloquer automatiquement après une limite (en minutes) :
```bash
# Exemple : Bloquer après 180 minutes (3h)
sudo ./timelimit.sh watch --domain facebook.com --limit 180 &
```

---

## 🛠️ Fonctionnement technique

Le script utilise la technique du **DNS Sinkhole** local :
1.  Il ajoute une entrée `127.0.0.1 www.facebook.com` dans votre fichier `/etc/hosts`.
2.  Toute requête vers Facebook est alors redirigée vers votre propre machine (localhost), ce qui rend le site inaccessible.
3.  Le script `timelimit.sh` calcule le temps d'activité et déclenche le blocage une fois le quota atteint.



## ⚠️ Limitations & Disclaimer

* **Cache DNS :** Votre navigateur peut garder Facebook en cache pendant quelques minutes après le blocage. Un redémarrage du navigateur ou un flush DNS peut être nécessaire.
* **HTTPS :** Ce script bloque la résolution de nom, il est donc efficace même pour les connexions sécurisées (SSL).
* **Responsabilité :** La modification de `/etc/hosts` affecte tous les utilisateurs de la machine. Utilisez-le avec discernement.

## 📝 Licence

Distribué sous la licence **MIT**. Voir `LICENSE` pour plus d'informations.

---

### Souhaitez-vous que je rédige également le script `timelimit.sh` pour qu'il gère réellement le calcul du temps (via le monitoring des processus ou du réseau) ?