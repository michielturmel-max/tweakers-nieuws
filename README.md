# Tweakers Nieuws

Nieuwsbalk-widget voor [Omarchy](https://omarchy.org): koppen uit RSS-feeds, websites en YouTube-kanalen in het bovenpaneel, met een lezer in het paneel en een eigen artikelarchief.

- Meerdere bronnen naast elkaar, als tabs in het uitklappaneel.
- Klik een kop om het artikel in het paneel te lezen; rechtsklik opent de browser.
- Bewaar een artikel met `s` in je archief en lees of doorzoek dat later terug.
- Alles volgt het Omarchy-thema en de systeembronnen.

## Vereisten

- Omarchy met de Quickshell-shell (`omarchy-shell`).
- `python3`, `curl` en `perl` (aanwezig op een standaard Omarchy-installatie).

## Downloaden en installeren

Er zijn twee manieren. De zip is het simpelst als je niet met git werkt; met een clone kun je later makkelijk updaten.

### Optie 1: zip uit de release

1. Ga naar [Releases](https://github.com/michielturmel-max/tweakers-nieuws/releases) en download `tweakers.nieuws-<versie>.zip` bij de nieuwste release.
2. Pak de zip uit, bijvoorbeeld naar `~/Downloads`.
3. Open een terminal in de uitgepakte map en voer uit:

   ```sh
   cd ~/Downloads/tweakers.nieuws
   ./install.sh install
   ```

   Staat de map ergens anders? `cd` er dan naartoe; de map moet `manifest.json`, `Panel.qml` en `install.sh` bevatten.

### Optie 2: met git

```sh
git clone https://github.com/michielturmel-max/tweakers-nieuws.git
cd tweakers-nieuws
./install.sh install
```

### Na de installatie

De widget zou meteen in de balk moeten staan. Is dat niet zo, herstart dan de shell of zet de plugin aan:

```sh
omarchy-restart-shell
# of:
omarchy plugin enable tweakers.nieuws
```

De eerste keer staan er drie voorbeeldbronnen in; pas ze aan via het hamburgermenu (☰). Je eigen bronlijst staat in `~/.config/omarchy/plugins/tweakers.nieuws/sources.json` en blijft bij een update bewaard.

## Bijwerken

Je bronlijst (`sources.json`) en je artikelarchief blijven bij een update bewaard; de oude installatie gaat eerst naar `~/.config/omarchy/plugin-backups/`.

**Zip of installatie via `./install.sh install`:** download de nieuwste `tweakers.nieuws-<versie>.zip` uit [Releases](https://github.com/michielturmel-max/tweakers-nieuws/releases), pak hem uit en voer in de uitgepakte map uit:

```sh
./install.sh update
```

`update` installeert alleen als de geïnstalleerde versie ouder is. Met `./install.sh version` zie je de gebundelde en de geïnstalleerde versie; `./install.sh install` overschrijft altijd.

**Git-clone:**

```sh
git pull
./install.sh update
```

**Geïnstalleerd via `omarchy plugin add`:** die installatie beheert Omarchy zelf als git-plugin; werk hem bij met:

```sh
omarchy plugin update tweakers.nieuws
```

`./install.sh help` toont alle opties, waaronder `uninstall`.

## Bediening

| Toets | Actie |
| --- | --- |
| `↑` `↓` | kies een kop in de lijst |
| `Enter` | lees de gekozen kop |
| `←` `→` | vorige/volgende bron; rechts voorbij de laatste tab opent het hamburgermenu |
| `1`–`9` | open die kop direct |
| `s` | bewaar het gelezen artikel in het archief |
| `r` | ververs de lijst of herlaad het artikel |
| `o` | open de site van de bron in de browser |
| `e` | bewerk de actieve bron |
| `esc` / `backspace` | één stap terug |

In een artikel: `←` of `esc`/`backspace` gaat terug naar de lijst, `→` naar het volgende artikel. Het artikelarchief zit onder `archief` in het hamburgermenu: de lijst opent meteen, het zoekveld filtert, een klik leest in het paneel en `↗` opent het artikel in de browser.

Het aantal koppen is in te stellen (1–10, standaard 10).

## Bronnen

Bronnen staan in `~/.config/omarchy/plugins/tweakers.nieuws/sources.json`. Toevoegen en bewerken kan ook via het hamburgermenu. Een bron is een RSS/Atom-feed (`url`) of een YouTube-kanaal (`youtube`).

## Meewerken

Suggesties en pull requests zijn welkom.

1. Fork de repo en maak een branch.
2. Wijzig `Panel.qml` en/of `bin/tweakers-nieuws`.
3. Test met `omarchy plugin validate .` en herstart de shell met `omarchy-restart-shell` (de hot-reload van de shell is niet altijd betrouwbaar).
4. Open een pull request met wat je verandert en waarom.

Houd de bestaande stijl aan: Nederlandse teksten, korte toelichtende comments waar de reden niet uit de code blijkt, geen nieuwe dependencies.

## Licentie

MIT, zie [LICENSE](LICENSE).
