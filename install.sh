#!/usr/bin/env bash
# Officiële Omarchy-plugininstallatie, -update en -verwijdering voor
# tweakers.nieuws. Werkend vanaf elke locatie: USB-stick, github-kopie,
# willekeurige map.
#
# Gebruikt alleen de officiële omarchy-plugin-tooling:
#   omarchy plugin validate <map>   schema + veiligheidschecks
#   omarchy-shell shell rescanPlugins
#   omarchy plugin enable <id> [sectie]
#   omarchy plugin remove  <id>     bij verwijderen (maakt zelf een backup)
#
# install: veilig opnieuw uit te voeren; de vorige installatie wordt eerst
#          bewaard en je eigen bronlijst (sources.json) blijft intact.
# update:  alleen installeren als de geïnstalleerde versie ouder is.
# version: laat gebundelde en geïnstalleerde versie zien.
# uninstall: verwijdert via de officiële tool; de map (met je bronlijst)
#          wordt automatisch geback-upt.
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SRC_DIR/manifest.json"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
BACKUPS_DIR="$HOME/.config/omarchy/plugin-backups"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf 'installer: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
gebruik: ./install.sh [commando]

commando:
  install     (standaard) installeer of ververs de plugin
  update      alleen installeer wanneer de geïnstalleerde versie ouder is
  version     vergelijk de gebundelde versie met de geïnstalleerde
  uninstall   verwijder de plugin via de officiële omarchy-tooling
  help        dit overzicht
EOF
}

require_omarchy() {
  command -v omarchy >/dev/null 2>&1 || fail "omarchy is niet gevonden; dit is een Omarchy-plugin (installeer eerst Omarchy)"
  command -v jq >/dev/null 2>&1 || fail "jq is niet geïnstalleerd"
}

plugin_id() {
  jq -r '.id // empty' "$MANIFEST"
}

bundled_version() {
  jq -r '.version // "0"' "$MANIFEST"
}

installed_version() {
  local id="$1"
  local m="$PLUGINS_DIR/$id/manifest.json"
  if [[ -f $m ]]; then
    jq -r '.version // "0"' "$m"
  else
    echo ""
  fi
}

is_git_checkout() {
  [[ -d "$PLUGINS_DIR/$1/.git" ]]
}

version() {
  require_omarchy
  [[ -f "$MANIFEST" ]] || fail "manifest.json niet gevonden naast de installer ($MANIFEST)"
  local id
  id=$(plugin_id)
  local installed
  installed=$(installed_version "$id")
  say "Versie-overzicht"
  info "gebundeld (deze map):  $(bundled_version)"
  if [[ -n $installed ]]; then
    info "geïnstalleerd:          $installed ($PLUGINS_DIR/$id)"
    if is_git_checkout "$id"; then
      info "beheerd via git -> updates via: omarchy plugin update $id"
    fi
  else
    info "niet geïnstalleerd op deze machine"
  fi
}

uninstall() {
  require_omarchy
  [[ -f "$MANIFEST" ]] || fail "manifest.json niet gevonden naast de installer ($MANIFEST)"
  local id
  id=$(plugin_id)
  [[ -n $id ]] || fail "manifest bevat geen id"
  say "[1/1] Plugin $id verwijderen via de officiële tool"
  if ! omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
    info "plugin $id is niet geïnstalleerd; niets te doen"
    return 0
  fi
  omarchy plugin remove "$id"
  info "verwijderd. Omarchy bewaarde de map automatisch; je bronlijst zit daarin."
  info "terugzetten kan door de map terug te kopiëren naar $PLUGINS_DIR/$id."
}

install() {
  require_omarchy
  [[ -f "$MANIFEST" ]] || fail "manifest.json niet gevonden naast de installer ($MANIFEST)"
  local id
  id=$(plugin_id)
  [[ -n $id ]] || fail "manifest bevat geen id"

  say "[1/5] Plugin valideren (officiële schema- en veiligheidscheck)"
  omarchy plugin validate "$SRC_DIR"
  info "ok: $id"

  say "[2/5] Kopiëren naar $PLUGINS_DIR/$id"
  local stage="$PLUGINS_DIR/.$id.install.$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -a "$SRC_DIR/manifest.json" "$SRC_DIR/Panel.qml" "$SRC_DIR/vrije-bronnen.json" "$stage/"
  cp -a "$SRC_DIR/bin" "$stage/bin"

  if python3 -m py_compile "$stage"/bin/*.py 2>/dev/null; then
    rm -rf "$stage"/bin/__pycache__
  else
    rm -rf "$stage"
    fail "een python-bron heeft een syntaxfout; niet geïnstalleerd"
  fi
  chmod +x "$stage"/bin/tweakers-nieuws "$stage"/bin/*.py

  local old_sources=""
  if [[ -e $PLUGINS_DIR/$id ]]; then
    local backup="$BACKUPS_DIR/$id-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    cp -a "$PLUGINS_DIR/$id/." "$backup/"
    if [[ -f "$backup/sources.json" ]]; then
      old_sources="$backup/sources.json"
    fi
    info "vorige installatie bewaard als: $backup"
  fi

  rm -rf "$PLUGINS_DIR/$id"
  mv "$stage" "$PLUGINS_DIR/$id"

  if [[ -n $old_sources ]]; then
    cp -a "$old_sources" "$PLUGINS_DIR/$id/sources.json"
    info "je eigen bronlijst (sources.json) is bewaard"
  elif [[ -f $SRC_DIR/sources.json ]]; then
    cp -a "$SRC_DIR/sources.json" "$PLUGINS_DIR/$id/sources.json"
    info "voorbeeldbronnen geplaatst (aan te passen via het ☰-menu)"
  fi

  say "[3/5] Plugins opnieuw laten ontdekken"
  omarchy-shell shell rescanPlugins >/dev/null || true

  say "[4/5] Inschakelen"
  if omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" 'any(.[]; .id == $id and .enabled)' >/dev/null 2>&1; then
    info "was al ingeschakeld"
  else
    local section
    section=$(jq -r '.barWidget.defaultSection // "center"' "$MANIFEST")
    for (( attempt = 0; attempt < 40; attempt++ )); do
      omarchy plugin list --json 2>/dev/null | jq -e --arg id "$id" 'any(.[]; .id == $id)' >/dev/null 2>&1 && break
      sleep 0.05
    done
    omarchy plugin enable "$id" "$section"
    info "ingeschakeld in het midden van de bar"
  fi

  say "[5/5] Klaar"
  info "Klik op het Nieuws-icoontje in de bar om het paneel te openen."
  info "Bekijk versies met: ./install.sh version"
  info "Verwijderen doe je met: ./install.sh uninstall"
}

update_() {
  require_omarchy
  [[ -f "$MANIFEST" ]] || fail "manifest.json niet gevonden naast de installer ($MANIFEST)"
  local id
  id=$(plugin_id)
  if is_git_checkout "$id"; then
    fail "deze installatie wordt via git beheerd; werk hem bij met: omarchy plugin update $id"
  fi
  local bundled installed
  bundled=$(bundled_version)
  installed=$(installed_version "$id")
  if [[ -n $installed ]]; then
    local newest
    newest=$(printf '%s\n%s\n' "$installed" "$bundled" | sort -V -r | head -1)
    if [[ $newest == "$installed" ]]; then
      say "Al actueel: $installed (bundel: $bundled)"
      return 0
    fi
    say "Update gevonden: geïnstalleerd $installed -> gebundeld $bundled"
  else
    say "Plugin nog niet geïnstalleerd; installeer versie $(bundled_version)"
  fi
  install
}

case "${1:-install}" in
  install|"") install ;;
  update) update_ ;;
  version|info) version ;;
  uninstall|remove|rm) uninstall ;;
  help|-h|--help) usage ;;
  *) fail "onbekend commando '$1' (zie: ./install.sh help)" ;;
esac