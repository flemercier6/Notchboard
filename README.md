# Notchboard

Une étagère (« shelf ») qui sort du notch de ton MacBook. Invisible par défaut,
elle s'ouvre quand la souris survole le notch. Glisse-y du texte ou des images,
puis re-copie-les plus tard où tu veux (email, message, etc.).

## Fonctionnalités (v1 — MVP)

- Panneau **collapsed / invisible** par défaut, ancré au notch.
- **Survol du notch → expand** (et collapse automatique quand la souris quitte).
- **Glisser-déposer** de texte et d'images dans l'étagère.
- Bouton **coller depuis le presse-papier**.
- Items affichés **alignés horizontalement** avec défilement.
- **Clic sur un item → copié** dans le presse-papier ; **glisser un item** vers une autre app.
- Largeur max de l'état ouvert = **60 % de la largeur de l'écran**.

## Lancer en dev

```bash
swift run
```

L'app tourne en arrière-plan (pas d'icône dans le Dock). `Ctrl+C` dans le
terminal pour l'arrêter.

## Construire un .app

```bash
./scripts/make-app.sh
open Notchboard.app
```

Pour la lancer au démarrage : Réglages Système → Général → Ouverture →
ajouter `Notchboard.app`.

## Ouvrir dans Xcode

```bash
xed .
```

Xcode ouvre directement le `Package.swift` ; sélectionne le schéma *Notchboard*
et fais Run.

## Architecture

| Fichier | Rôle |
|---|---|
| `main.swift` | Point d'entrée, app accessory (sans Dock). |
| `AppDelegate.swift` | Crée la fenêtre, la repositionne quand l'écran change. |
| `NotchWindow.swift` | `NSPanel` borderless ancré au notch, anime collapse/expand. |
| `NotchMetrics.swift` | Géométrie réelle du notch (avec fallback sans notch). |
| `ShelfStore.swift` | Modèle des items + pont avec le presse-papier. |
| `NotchViewModel.swift` | État ouvert/fermé piloté par le survol. |
| `NotchView.swift` | UI SwiftUI : zone de drop, scroll horizontal, contrôles. |
| `ShelfItemView.swift` | Une tuile : copier (clic), glisser, supprimer. |

## Limites connues / pistes v2

- Pas encore de **persistance** : l'étagère se vide au redémarrage.
- Quand le panneau est ouvert, sa zone (y compris les bords transparents)
  capture les clics ; il se referme dès que la souris sort. Un vrai
  *click-through* par région reste à faire.
- Raccourci clavier global pour coller, réordonnancement des items, et
  réglage de la largeur — à venir.
