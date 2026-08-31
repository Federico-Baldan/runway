# Runway — sistema di marchio

Direzione scelta: **notch**. La forma dove l'app vive letteralmente — una tacca
appesa al bordo superiore di un display scuro, con la spia di stato dove un
MacBook tiene la fotocamera.

## Il problema risolto

Nel round 1 questa direzione cedeva sotto i 32 px. La diagnosi iniziale era
sbagliata: non era la tacca nera a non funzionare — una tacca *è* assenza di
schermo, e nera è la lettura giusta — era il **fondo** a non darle contrasto.

Nero su `#1C1F27` sta a **1.27:1**, sotto la soglia dove un bordo sopravvive
all'antialiasing. La correzione è alzare il gradiente dello squircle, non
schiarire la tacca:

| | Fondo, alto | Contrasto tacca/fondo |
|---|---|---|
| prima | `#1C1F27` | 1.27:1 |
| ora, ≥17 pt | `#2B303B` | 1.60:1 |
| ora, ≤16 pt | `#454E5F` | 2.53:1 |

## Scala ottica

Tre disegni, non uno rimpicciolito. Man mano che il canvas si stringe la tacca
si allarga, il fondo si alza e **il punto cresce** — il punto è l'unico elemento
ad alto contrasto (verde su nero), quindi è quello che deve portare il peso
quando lo spazio finisce.

| Dimensione | Larghezza tacca | Profondità | Punto | Gradiente |
|---|---|---|---|---|
| ≥ 128 pt | 0.56 × lato | 0.42 × lato | r 0.10 | `#2B303B` → `#0D0F14` |
| 17–64 pt | 0.58 × lato | 0.40 × lato | r 0.115 | `#323947` → `#0F1218` |
| ≤ 16 pt | 0.70 × lato | 0.34 × lato | r 0.13 | `#454E5F` → `#14171E` |

A 16 px una tacca larga 0.56 sono nove pixel di quasi-nero su scuro e
spariscono; una larga 0.70 resta un'interruzione. A quella dimensione l'identità
è «tessera scura, bordo superiore morso, luce verde» — le proporzioni della cosa
vera sono un lusso dei tagli grandi.

Tacca sempre `#000000`. Raggio dell'angolo inferiore = metà della profondità.
Squircle r = 0.2237 × lato (rapporto Apple). La tacca è **clippata sullo
squircle**: vicino agli angoli il bordo superiore sta già curvando, e senza clip
una tacca larga sborderebbe.

Questa tabella è implementata in `scripts/make-icon.swift` (`Geometry.forPoints`).
`make icon` rigenera `Resources/AppIcon.icns`.

## Colore

| Ruolo | Hex | Note |
|---|---|---|
| Accento / live | `#33D16B` | Già in codice: `NSColor(0.20, 0.82, 0.42)`, coerente con `StatusStyle.success` |
| Tacca | `#000000` | Nero pieno a ogni dimensione |
| Ink | `#0E1015` | Wordmark su fondo chiaro |
| Reverse | `#F2F4F0` | Wordmark e simbolo su fondo scuro |
| Squircle | vedi tabella | Il gradiente varia con la dimensione ottica |

Una sola tinta satura in tutto il sistema. Il blu «in corso» resta linguaggio
d'interfaccia, non di marchio.

## Proporzioni dei lockup

**Simbolo autonomo** — la barra dei menu con la tacca appesa, senza squircle.
Barra `96 × 5.5`, tacca `32 × 23`, raggio inferiore `11.5`. Il rapporto che conta
è **barra : tacca = 3 : 1** — la tacca è un'interruzione della barra, non un
oggetto appeso sotto. Una tacca più larga di un terzo della barra smette di
leggersi come notch.

**Impilato** — larghezza del simbolo `W` come unità (il simbolo è alto `0.24 W`):

- corpo wordmark = `0.27 × W`
- spazio fra base della tacca e altezza-maiuscola = `0.13 × W`
- area di rispetto = `0.25 × W` su ogni lato
- dimensione minima: `W = 96 px`. Sotto, usare l'icona.
- la wordmark è centrata **sull'inchiostro**, non sull'avanzamento: l'avanzamento
  porta con sé il fianco destro della `y` e sposterebbe la parola fuori asse.

**Orizzontale** — lato dell'icona `S` come unità:

- corpo wordmark = `0.58 × S`
- spazio fra icona e wordmark = `0.26 × S`
- area di rispetto = `0.30 × S`
- dimensione minima: `S = 40 px`

Wordmark: **Inter 600**, tracking −3.2%, **convertita in tracciati**. Nessun
SVG del sistema dipende da un font installato. La crenatura è quella vera di
Inter (`wa` e `ay` crenano entrambe), applicata via HarfBuzz in fase di
conversione. Licenza SIL OFL, ridistribuibile.

## File | File | Uso |
|---|---|
| `appicon-large.svg` | Riferimento del taglio ≥ 128 pt, e testata del README |
| `favicon.svg` | Favicon 16/32 px — il taglio ≤ 16 pt |
| `symbol-notch.svg` | Simbolo autonomo, su fondo chiaro |
| `symbol-notch-reverse.svg` | Simbolo autonomo, su fondo scuro |
| `symbol-notch-mono.svg` | Un colore, punto in negativo |
| `lockup-stacked-light.svg` / `-dark.svg` | Lockup impilato |
| `lockup-horizontal-light.svg` / `-dark.svg` | Lockup orizzontale, per il README |

Gli altri tagli dell'icona non sono file: li possiede
`scripts/make-icon.swift`, e la barra dei menu li possiede
`Sources/Runway/UI/BrandMark.swift`. Un SVG gemello di geometria già scritta in
codice è solo una cosa che va fuori sincrono.

## README su GitHub

GitHub cambia tema da solo, quindi servono entrambe le versioni:

```html
<picture>
  <source media="(prefers-color-scheme: dark)"
          srcset="design/brand/lockup-horizontal-dark.svg">
  <img alt="Runway" width="330"
       src="design/brand/lockup-horizontal-light.svg">
</picture>
```

## Punti aperti

- Il fondo alzato rende l'icona più chiara di prima nel Dock. Se accanto alle
  altre app risulta troppo grigia, si abbassa `gradientTop` del solo passo
  ≥ 128 pt: i tre scalini sono indipendenti.
- Manca una variante «run fallita». Se serve un'icona rossa di stato va decisa
  ora, perché stabilisce se il rosso entra nel sistema di marchio o resta
  linguaggio d'interfaccia.
- `Resources/AppIcon.icns` è ancora quello vecchio: va rigenerato con
  `make icon` su macOS.

## Barra dei menu

Collegata. `BrandMark.statusItem()` in `Sources/Runway/UI/BrandMark.swift`
disegna la tacca con il punto in negativo e la restituisce come template image,
così macOS la inverte da solo per la barra chiara. Sostituisce
`smallcircle.filled.circle` **solo** nello stato `.idle`: running, failed,
success ed error continuano a parlare in SF Symbols, perché stanno dicendo
qualcosa e il marchio no.

`menubar-template.svg` resta come riferimento visivo della stessa geometria.
