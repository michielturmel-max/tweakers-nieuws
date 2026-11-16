import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// De nieuwskoppen van meerdere bronnen, opgehaald op het moment dat het paneel
// opengaat. Bovenin staan tabs om tussen de bronnen te wisselen; een bron is
// een RSS-feed of een YouTube-kanaal, geconfigureerd in sources.json naast de
// widget. Klikken op een kop opent het hele artikel in het paneel zelf;
// rechtsklik gaat alsnog naar de browser.
//
// De lijst wordt niet in de achtergrond bijgehouden. Vijf koppen verouderen
// niet, en een widget die op de hele dag een request doet om een getal dat
// niemand leest is precies het soort werk dat een accu op een machine van
// deze leeftijd het liefst niet ziet.
Panel {
  id: root
  moduleName: "tweakers.nieuws"
  ipcTarget: "tweakers.nieuws"

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : 26

  readonly property string scriptPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/tweakers.nieuws/bin/tweakers-nieuws"
  readonly property int count: Math.max(1, Math.min(10, setting("count", 10)))

  readonly property int bodyFont: Style.font.body
  readonly property int captionFont: Style.font.caption
  readonly property int subtitleFont: Style.font.subtitle

  property int articleFontDelta: Math.max(-2, Math.min(12, Number(setting("articleFontSize", 0))))
  readonly property int articleTitleFont: Math.max(10, root.subtitleFont + root.articleFontDelta)
  readonly property int articleLeadFont: Math.max(10, root.bodyFont + root.articleFontDelta)
  readonly property int articleTextFont: Math.max(9, root.captionFont + root.articleFontDelta)

  property var sources: []
  // De tabbalk toont hooguit drie bronnen; de rest zit in het menu. tabModel
  // draagt echte bron-indexen, want de rijpositie is niet de bronpositie.
  property var tabModel: []
  property int sourceIndex: 0

  // Voor welke bron het lopende request was. Wissel je van bron terwijl een
  // request onderweg is, dan hoort het antwoord daar niet meer bij.
  property int pendingSource: -1

  readonly property var activeSource: {
    if (!sources.length) return null
    var i = Math.max(0, Math.min(sources.length - 1, sourceIndex))
    return sources[i]
  }

  // Voor youtube-bronnen krijgt elke kop een linkje dat de video opent op
  // youtube.com, naast het in-paneel lezen van de beschrijving.
  readonly property bool isYoutube: activeSource ? activeSource.key === "youtube" : false

  property var items: []
  property string fetchState: ""
  property string message: ""
  property int hoveredIndex: -1
  // Toetscursor in de koppenlijst: welke kop enter opent.
  property int listCursor: -1

  // Bron bewerken. De waarde is de kanaalnaam of de feed-URL van de actieve
  // bron, afhankelijk van welke sleutel die bron gebruikt.
  property bool editing: false
  property string editValue: ""
  property string editState: ""
  property string editError: ""

  // Bronbeheer: het hamburgermenu rechts. menuFormMode is "" (gesloten),
  // "add" (nieuwe bron) of "edit" (bestaande bron bewerken); menuTarget is
  // dan de bron die bewerkt wordt. Waarde- en naamswijziging lopen als twee
  // set-opdrachten achter elkaar; de naam hoeft pas aangestuurd te worden
  // als de gebruiker hem zelf heeft aangeraakt, anders geldt auto-naam.
  property bool menuMode: false
  property string menuFormMode: ""
  property int menuTarget: -1
  // Toetscursor in het menu: welke bronrij actief is voor de pijltjestoetsen.
  // Beweegt los van muisaanwijzer; -1 betekent "niets gekozen".
  property int menuCursor: -1
  property string manageError: ""
  property var pendingNameEdit: null
  property int pendingJump: -1
  property bool changeReload: false
  // In-flight-bescherming: de proc voor een actie wordt pas gestart als de
  // vorige klaar is. Wachtend werk onthouden we hier, zodat snelle klikken
  // niet door elkaar raken en geen enkele actie verloren gaat.
  property var pendingManageCmd: null
  property var pendingSetCmd: null
  property var pendingSearchTerm: null
  property int pendingFetch: -1
  property bool pendingSourcesReload: false
  property int pendingArticle: -1

  // YouTube-kanalen zoeken vanuit het toevoegformulier. searchResults is de
  // lijst van het script (name/handle/subscribers); een rij aanklikken vult
  // een nieuwe bron.
  property bool searching: false
  property var searchResults: []
  property string searchError: ""

  // Geopende artikel-archief zoeken (menu-formulier "archief").
  property bool archiveSearching: false
  property var archiveResults: []
  property string archiveError: ""

  // Start met typen voor de actieve bron. Doet niets als die bron geen
  // bewerkbare sleutel heeft.
  function startEdit() {
    if (!activeSource || !activeSource.key) return
    editing = true
    editValue = activeSource.value || ""
    editState = ""
    editError = ""
  }

  function cancelEdit() {
    editing = false
    editValue = ""
    editState = ""
    editError = ""
    editor.focus = false
  }

  function runSet(cmd) {
    if (setProc.running) { pendingSetCmd = cmd; return }
    setProc.command = cmd
    setProc.running = true
  }

  function runPendingSet() {
    if (!pendingSetCmd) return
    var c = pendingSetCmd
    pendingSetCmd = null
    setProc.command = c
    setProc.running = true
  }

  function saveEdit() {
    if (!editing || editState === "bezig") return
    if (!activeSource || !activeSource.key) { cancelEdit(); return }

    var value = String(editValue || "").trim()
    if (value === "") { cancelEdit(); return }

    editState = "bezig"
    runSet([scriptPath, "set", String(sourceIndex), activeSource.key, value])
  }

  function applySet(raw) {
    var text = String(raw || "").trim()

    if (text !== "ok") {
      // Eerste regel: het script spreekt mensentaal, dus nemen we die
      // ongewijzigd over.
      var first = text.split("\n")[0] || "opslaan mislukt"
      if (menuMode) {
        manageError = first
        menuValueField.forceActiveFocus()
      } else {
        editError = first
        editState = "fout"
        editor.forceActiveFocus()
      }
      runPendingSet()
      return
    }

    // Twee stappen voor een bron waarvan ook de naam handmatig is
    // opgegeven: eerst de waarde (die hernoemt automatisch), daarna de
    // handmatige naam er weer overheen.
    if (pendingNameEdit) {
      var pe = pendingNameEdit
      pendingNameEdit = null
      runSet([scriptPath, "set", String(pe.index), "name", pe.name])
      return
    }

    if (menuMode) menuFormMode = ""
    cancelEdit()
    // Na een andere kanaalnaam is ook de lijst van die bron achterhaald.
    reloadAfterChange(-1)
    runPendingSet()
  }

  // Na een bewerking in het menu moeten zowel de tablijst als de koppen van
  // de zichtbare bron opnieuw. Sources ophalen; zodra die binnen zijn, gaat
  // applySources verder (naar de nieuwe bron, of een verversing van de
  // huidige).
  function reloadAfterChange(jump) {
    pendingJump = jump
    changeReload = true
    if (sourcesProc.running) { pendingSourcesReload = true; return }
    sourcesProc.command = [scriptPath, "sources"]
    sourcesProc.running = true
  }

  function toggleMenu() {
    menuMode = !menuMode
    menuFormMode = ""
    menuTarget = -1
    menuCursor = -1
    manageError = ""
    resetSearch()
    closeArticle()
    blurMenu()
    if (!menuMode) return
    flick.contentY = 0
  }

  function blurMenu() {
    menuValueField.focus = false
    menuNameField.focus = false
    menuSearchField.focus = false
  }

  function openMenuForm(mode, i) {
    menuFormMode = mode
    menuTarget = i
    manageError = ""
    resetSearch()
    if (mode === "add") {
      menuTitle.text = "nieuwe bron"
      menuValueField.text = ""
      menuNameField.text = ""
    } else {
      var s = sources[i]
      if (!s) { menuFormMode = ""; return }
      menuTitle.text = "bron bewerken"
      menuValueField.text = s.value || ""
      menuNameField.text = s.name || ""
    }
    Qt.callLater(function() {
      menuValueField.forceActiveFocus()
      menuValueField.selectAll()
    })
  }

  function menuAddMode() { openMenuForm("add", -1) }
  function menuEdit(i) { openMenuForm("edit", i) }

  // Klik op een bron in het menu: niet bewerken maar die bron bekijken.
  // setSource begint zelf de ophaalactie; het menu moet alleen nog dicht.
  function menuOpen(i) {
    if (menuMode) toggleMenu()
    setSource(i)
  }

  function menuSave() {
    if (menuFormMode !== "add" && menuFormMode !== "edit") return
    var s = menuFormMode === "edit" ? sources[menuTarget] : null
    if (menuFormMode === "edit" && !s) { menuFormMode = ""; return }

    var v = String(menuValueField.text || "").trim()
    var n = String(menuNameField.text || "").trim()
    if (v === "") {
      // Nooit een klik op een zoekresultaat vereisen: als de waarde leeg is
      // omdat de gebruiker eerst zocht, dan is het bovenste resultaat wat hij
      // bedoelt.
      if (menuFormMode === "add" && searchResults.length > 0) {
        var r = searchResults[0]
        var rv = r.kind === "feed"
          ? String(r.value || "")
          : String(r.handle || "") !== "" ? "@" + String(r.handle).replace(/^@/, "") : ""
        if (rv !== "") {
          manage("add", [rv, String(r.name || "")])
          return
        }
      }
      manageError = "vul een @kanaal of feed-url in"
      return
    }

    if (menuFormMode === "add") {
      manage("add", [v, n])
      return
    }

    var vChanged = v !== String(s.value || "")
    var nChanged = n !== String(s.name || "")
    if (!vChanged && !nChanged) {
      menuFormMode = ""
      blurMenu()
      return
    }
    if (vChanged) {
      // De naam telt alleen als de gebruiker hem veranderd heeft; anders
      // mag de automatische naam de bron volgen. De feitelijke sleutel
      // (url of youtube) leidt het script zelf uit de waarde af.
      pendingNameEdit = nChanged ? { index: menuTarget, name: n } : null
      runSet([scriptPath, "set", String(menuTarget), "url", v])
      return
    }
    runSet([scriptPath, "set", String(menuTarget), "name", n])
  }

  // Eén proces voor toevoegen, verplaatsen en verwijderen; die antwoorden
  // kort ("ok" of "ok <index>"), zonder de omweg van een lijst.
  function manage(op, args) {
    manageError = ""
    var cmd = [scriptPath, op].concat(args)
    if (manageProc.running) { pendingManageCmd = cmd; return }
    manageProc.command = cmd
    manageProc.running = true
  }

  function runPendingManage() {
    if (!pendingManageCmd) return
    var c = pendingManageCmd
    pendingManageCmd = null
    manageProc.command = c
    manageProc.running = true
  }

  function resetSearch() {
    searching = false
    searchResults = []
    searchError = ""
    archiveSearching = false
    archiveResults = []
    archiveError = ""
    menuSearchField.text = ""
  }

  function runSearch(term) {
    searching = true
    searchError = ""
    if (searchProc.running) { pendingSearchTerm = { kind: "yt", term: term }; return }
    searchProc.command = [scriptPath, "search", term]
    searchProc.running = true
  }

  function runArchiveSearch(term) {
    if (term === undefined)
      term = String(menuSearchField.text || "").trim()
    term = String(term || "").trim()
    root.archiveSearching = true
    root.archiveError = ""
    if (searchProc.running) { pendingSearchTerm = { kind: "archief", term: term }; return }
    searchProc.command = [scriptPath, "archief-zoek", term]
    searchProc.running = true
  }

  function startSearch() {
    var term = String(menuSearchField.text || "").trim()
    if (term === "") { searchResults = []; searchError = ""; return }
    runSearch(term)
  }

  function applySearch(raw) {
    searching = false
    archiveSearching = false
    var text = String(raw || "").trim()
    var d = null
    try {
      d = JSON.parse(text)
    } catch (e) {
      d = null
    }
    if (menuFormMode === "archief") {
      archiveResults = d && d.results ? d.results : []
      archiveError = d && d.ok === 1 ? "" : (d && d.reason ? d.reason : "zoeken mislukt")
    } else {
      searchResults = d && d.results ? d.results : []
      searchError = d && d.ok === 1 ? "" : (d && d.reason ? d.reason : "zoeken mislukt")
    }

    if (pendingSearchTerm) {
      var p = pendingSearchTerm
      pendingSearchTerm = null
      if (p.kind === "archief") runArchiveSearch(p.term)
      else runSearch(p.term)
    }
  }

  function applyManage(raw) {
    var text = String(raw || "").trim()
    var first = text.split("\n")[0].trim()
    var ok = first === "ok" || /^ok \s*\d+$/.test(first)
    if (!ok) {
      manageError = first || "actie mislukt"
      runPendingManage()
      return
    }

    var jump = -1
    var m = first.match(/ok \s*(\d+)/)
    if (m) jump = parseInt(m[1], 10)

    // Het formulier sluit; de nieuwe/gewijzigde situatie is meteen zichtbaar.
    menuFormMode = ""
    menuNameField.text = ""
    resetSearch()
    blurMenu()
    reloadAfterChange(jump)
    runPendingManage()
  }

  // Artikelweergave. articleState is "bezig" tijdens het ophalen; "fout"
  // betekent dat we terugvallen op de browser in plaats van een leeg venster
  // te tonen.
  property bool articleMode: false
  property var article: null
  property string articleState: ""
  property int articleIndex: -1
  // De url van het geopende artikel, los van items: nodig voor het archief
  // (opslaan) en voor artikelen die via een zoekhit worden geopend.
  property string articleUrl: ""
  property string pendingArticleUrl: ""
  property string archiveMsg: ""
  // Onthoud of het artikel uit het archief kwam, zodat terug ook weer naar
  // de archieflijst gaat in plaats van naar de koppen.
  property bool articleFromArchive: false

  // Automatische nieuwsalert voor de drie "main"-bronnen naast het
  // hamburgermenu: poll elke 5 minuten de koppen en laat het script een
  // omarchy-notificatie geven voor écht nieuwe artikelen (zonder dat er
  // iemand het paneel hoeft te openen).
  readonly property var prikSources: [1, 2, 3]
  readonly property int prikIntervalMs: 5 * 60 * 1000
  property var prikQueue: []
  property bool prikBusy: false

  function pollKops() {
    for (var p = 0; p < root.prikSources.length; p++) {
      var pidx = root.prikSources[p]
      if (pidx < 0) continue
      if (root.prikQueue.indexOf(pidx) !== -1) continue
      root.prikQueue = root.prikQueue.concat([pidx])
    }
    root.runNextPrik()
  }

  function runNextPrik() {
    if (root.prikBusy || root.prikQueue.length === 0) return
    root.prikBusy = true
    var pidx = root.prikQueue[0]
    root.prikQueue = root.prikQueue.slice(1)
    prikProc.command = [scriptPath, "--source", String(pidx), "prik"]
    prikProc.running = true
  }

  function doFetch(index) {
    fetchState = "bezig"
    pendingSource = index
    fetchProc.command = [scriptPath, "--count", String(count), "--source", String(index)]
    fetchProc.running = true
  }

  function refresh() {
    // Een lopende ophaalbeurt niet overschrijven; onthoud de nieuw gevraagde
    // bron (bijv. na snel van tab wisselen) en haal die op zodra de huidige
    // klaar is.
    if (fetchProc.running) { pendingFetch = sourceIndex; return }
    doFetch(sourceIndex)
  }

  // Wissel van bron, of ververs dezelfde bron met force. De lijst per bron
  // staat in het script gecached, dus terugkomen naar een bron die je al had
  // gezien is gratis.
  function setSource(index, force) {
    if (index < 0 || index >= sources.length) return
    if (index === sourceIndex && !force) return

    if (index !== sourceIndex) {
      sourceIndex = index
      items = []
      message = ""
      fetchState = ""
      listCursor = -1
      closeArticle()
    }
    flick.contentY = 0
    refresh()
  }

  function switchSource(direction) {
    if (sources.length < 2) return
    setSource((sourceIndex + direction + sources.length) % sources.length)
  }

  // Pijltjes over de topbalk: de tabs én het hamburgermenu als één kringloop.
  // Rechts na de laatste tab (en links aan het begin) land je op het menu,
  // geopend bij de rij die er op die plek het dichtste bij zit.
  function topArrow(direction) {
    if (!tabModel.length || menuMode) return
    if (direction > 0) {
      if (sourceIndex >= tabModel.length - 1) {
        openMenuAtRow(Math.min(sourceIndex + 1, sources.length - 1))
      } else {
        switchSource(1)
      }
    } else {
      if (sourceIndex <= 0) {
        openMenuAtRow(sourceIndex === 0 ? sources.length - 1 : 0)
      } else {
        switchSource(-1)
      }
    }
  }

  // Menu openen op een specifieke bronrij, met de toetscursor daarop.
  function openMenuAtRow(i) {
    if (!sources.length) return
    if (!menuMode) toggleMenu()
    menuCursor = Math.max(0, Math.min(sources.length - 1, i))
    Qt.callLater(function() { scrollMenuTo(menuCursor) })
  }

  // Beweeg de toetscursor door de bronrijen van het menu (links/rechts en
  // omhoog/omlaag betekenen hier hetzelfde: de regels staan verticaal).
  function menuArrow(direction) {
    if (menuFormMode !== "" || !sources.length) return
    var n = menuCursor < 0 ? sourceIndex : menuCursor
    n = (n + direction + sources.length) % sources.length
    menuCursor = n
    scrollMenuTo(n)
  }

  // Zorg dat de cursorrij in beeld blijft, ook als het menu scrollt.
  function scrollMenuTo(i) {
    var item = menuRows.itemAt(i)
    if (!item || !flick.contentItem) return
    var pt = item.mapToItem(flick.contentItem, 0, 0)
    if (pt.y < flick.contentY) {
      flick.contentY = pt.y
    } else if (pt.y > flick.contentY + flick.height) {
      flick.contentY = pt.y
    }
  }

  // Toetscursor door de koppen: omhoog/omlaag kiest een kop, enter leest hem.
  function listArrow(direction) {
    if (!items.length) return
    var n = listCursor < 0 ? (direction > 0 ? 0 : items.length - 1) : listCursor + direction
    listCursor = Math.max(0, Math.min(items.length - 1, n))
    scrollListTo(listCursor)
  }

  function scrollListTo(i) {
    var item = newsRows.itemAt(i)
    if (!item || !flick.contentItem) return
    var pt = item.mapToItem(flick.contentItem, 0, 0)
    if (pt.y < flick.contentY) {
      flick.contentY = pt.y
    } else if (pt.y + item.height > flick.contentY + flick.height) {
      flick.contentY = Math.min(pt.y, Math.max(0, flick.contentHeight - flick.height))
    }
  }

  function applySources(raw) {
    var text = String(raw || "").trim()
    if (text.charAt(0) !== "[") return

    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      parsed = null
    }

    if (!Array.isArray(parsed) || parsed.length === 0) return
    sources = parsed

    // Tabbalk = drie snelkoppelingen; bronnen daarbuiten leven in het menu.
    var shown = Math.min(3, parsed.length)
    var tm = []
    for (var i = 0; i < shown; i++) tm.push({ index: i, name: parsed[i].name || "" })
    tabModel = tm

    if (sourceIndex >= parsed.length) sourceIndex = 0

    // Na een beheeractie: spring naar een nieuwe bron (bij toevoegen) of
    // ververs de huidige lijst (na wijzigen/verplaatsen/verwijderen).
    if (pendingJump >= 0 && parsed.length) {
      var j = pendingJump
      pendingJump = -1
      setSource(Math.min(j, parsed.length - 1), true)
    } else if (changeReload) {
      changeReload = false
      setSource(sourceIndex, true)
    }

    if (pendingSourcesReload) {
      pendingSourcesReload = false
      pendingJump = -1
      changeReload = true
      sourcesProc.command = [scriptPath, "sources"]
      sourcesProc.running = true
    }
  }

  // Het script praat JSON, maar een fout (netwerk weg, consent-gate die
  // plots verandert) komt als vrije tekst terug. Beide landen hier.
  function applyOutput(raw) {
    if (pendingSource !== sourceIndex) {
      if (pendingFetch >= 0) {
        var fi = pendingFetch
        pendingFetch = -1
        doFetch(fi)
      }
      return
    }

    var text = String(raw || "").trim()
    if (text.charAt(0) !== "[") {
      message = text.split("\n")[0] || "kon de koppen niet ophalen"
      fetchState = "fout"
      if (pendingFetch >= 0) {
        var fi2 = pendingFetch
        pendingFetch = -1
        doFetch(fi2)
      }
      return
    }

    var parsed = null
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      parsed = null
    }

    if (!Array.isArray(parsed)) {
      message = "onleesbaar antwoord van het script"
      fetchState = "fout"
      if (pendingFetch >= 0) {
        var fi3 = pendingFetch
        pendingFetch = -1
        doFetch(fi3)
      }
      return
    }

    items = parsed
    message = ""
    fetchState = parsed.length ? "" : "leeg"

    if (pendingFetch >= 0) {
      var fi4 = pendingFetch
      pendingFetch = -1
      doFetch(fi4)
    }
  }

  function openArticle(index) {
    var item = items[index]
    if (item && item.url) { Qt.openUrlExternally(item.url); return }
    if (articleUrl) Qt.openUrlExternally(articleUrl)
  }

  // Toont de volledige tekst van een artikel in het paneel. Sluit het paneel
  // niet: de gebruiker wil terug kunnen naar de lijst.
  function showArticle(index) {
    var item = items[index]
    if (!item || !item.url) return

    if (articleMode && articleIndex === index && article) return

    // Snel achter elkaar klikken kan maar één artikel tegelijk ophalen; de
    // nieuwste klik wint en verschijnt zodra het lopende verzoek klaar is.
    if (articleProc.running) { pendingArticle = index; return }

    articleIndex = index
    articleMode = true
    article = null
    articleState = "bezig"
    articleUrl = item.url
    hoveredIndex = -1
    flick.contentY = 0

    articleProc.command = [scriptPath, "article", item.url]
    articleProc.running = true
  }

  function closeArticle() {
    // Terug uit een artikel: de cursor landt op de kop die je las, zodat
    // verder bladeren doorgaat waar je was.
    if (articleIndex >= 0) listCursor = articleIndex
    articleMode = false
    article = null
    articleState = ""
    articleIndex = -1
    hoveredIndex = -1
    pendingArticle = -1
    pendingArticleUrl = ""
    articleUrl = ""
    articleFromArchive = false
    flick.contentY = 0
  }

  // Terug uit een artikel: naar het archief als het daar vandaan kwam,
  // anders naar de koppenlijst met de cursor op de gelezen kop.
  function backFromArticle() {
    var toArchive = articleFromArchive
    closeArticle()
    if (toArchive) menuArchiveMode()
  }

  // Een artikel direct op zijn url openen, zonder dat het in items zit
  // (bijv. een hit uit het artikel-archief).
  function showArticleUrl(url) {
    if (!url) return
    if (articleMode && articleUrl === url && article) return
    if (articleProc.running) { pendingArticleUrl = url; return }

    articleIndex = -1
    articleMode = true
    article = null
    articleState = "bezig"
    articleUrl = url
    hoveredIndex = -1
    flick.contentY = 0

    articleProc.command = [scriptPath, "article", url]
    articleProc.running = true
  }

  // Het geopende artikel in het archief plaatsen (markdown, opmaak behouden).
  function saveCurrentArticle() {
    if (!articleMode || !articleUrl || archiveProc.running) return
    archiveMsg = "opslaan \u2026"
    archiveProc.command = [scriptPath, "opslaan", articleUrl]
    archiveProc.running = true
  }

  function applyArchive(raw) {
    var first = String(raw || "").trim().split("\n")[0] || "niet opgeslagen"
    archiveMsg = first
    archiveMsgTimer.restart()
    root.toast(first, root.article && root.article.title ? root.article.title : "")
  }

  // Een omarchy-toast (rechtsboven, ~5 s) als onmiddellijk zichtbare
  // bevestiging — het paneel-vakje kan tussen een lang artikel verdwalen.
  function toast(summary, body) {
    if (!summary) return
    toastProc.command = ["notify-send", "-t", "5000", "-a", "tweakers-nieuws", String(summary), String(body || "")]
    toastProc.running = true
  }

  // In het hamburgermenu het artikel-archief tonen: meteen de volledige
  // lijst (nieuwste eerst), het zoekveld filtert die lijst.
  function menuArchiveMode() {
    menuMode = true
    menuFormMode = "archief"
    menuTarget = -1
    menuTitle.text = "artikel-archief"
    resetSearch()
    runArchiveSearch("")
    Qt.callLater(function() { menuSearchField.forceActiveFocus() })
  }

  function openArchiveResult(i) {
    var r = archiveResults[i]
    if (!r || !r.url) return
    menuFormMode = ""
    menuMode = false
    blurMenu()
    resetSearch()
    closeArticle()
    articleFromArchive = true
    showArticleUrl(r.url)
  }

  // Zelfde artikel, maar in de browser in plaats van in het paneel.
  function openArchiveExternal(i) {
    var r = archiveResults[i]
    if (!r || !r.url) return
    if (root.bar) root.bar.run("omarchy-launch-browser " + r.url)
    else Qt.openUrlExternally(r.url)
  }

  // Als een site tot de curl-limiet van het script blijft hangen, moet het
  // paneel niet eindeloos op "artikel laden…" blijven staan. Na deze limiet
  // geldt hetzelfde beleid als bij een kapot artikel: de browser in.
  function articleTimeout() {
    if (!(articleMode && articleState === "bezig")) return
    articleState = "fout"
    var url = articleUrl
    var item = items[articleIndex]
    if (!url && item) url = item.url || ""
    pendingArticle = -1
    closeArticle()
    if (url) Qt.openUrlExternally(url)
  }

  // Eén plek voor "een stap terug". Vanuit het tekstveld is dat de editor
  // annuleren, vanuit de lijst sluiten, vanuit een artikel terug naar de
  // lijst. Zo werkt Escape ook in elk ander programma met een drill-down, en
  // het hoeft dus niet apart uitgelegd te worden.
  function goBack() {
    if (editing) {
      cancelEdit()
      return
    }
    if (menuMode) {
      // Eerste esc tilt de focus van een openveld; de tweede sluit het
      // formulier, de derde verlaat de beheerweergave.
      if (menuValueField.activeFocus || menuNameField.activeFocus || menuSearchField.activeFocus) {
        blurMenu()
        return
      }
      if (menuFormMode !== "") {
        menuFormMode = ""
        manageError = ""
        resetSearch()
        return
      }
      toggleMenu()
      refresh()
      return
    }
    if (articleMode) {
      backFromArticle()
      return
    }
    close()
  }

  function applyArticle(raw) {
    // Een tweede klik stond al klaar: eerst die openen, het net voltooide
    // artikel overslaan.
    if (pendingArticleUrl !== "") {
      var pu = pendingArticleUrl
      pendingArticleUrl = ""
      showArticleUrl(pu)
      return
    }
    if (pendingArticle >= 0) {
      var ni = pendingArticle
      pendingArticle = -1
      showArticle(ni)
      return
    }
    // Intussen weggegaan (esc of ←): dit antwoord is niet meer nodig en mag
    // de lijst niet meer binnendringen.
    if (!articleMode) return

    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "").trim())
    } catch (e) {
      parsed = null
    }

    // Geen bruikbaar artikel: dan maar de browser. Een leeg venster met een
    // foutmelding is voor dit doel nutteloos, en dit pad hoort zelden voor te
    // komen omdat het script zelf al faalt als de pagina omgegooid is.
    if (!parsed || !parsed.ok || !Array.isArray(parsed.blocks) || parsed.blocks.length === 0) {
      articleState = "fout"
      var item = items[articleIndex]
      var fallbackUrl = (item && item.url) ? item.url : articleUrl
      if (fallbackUrl) Qt.openUrlExternally(fallbackUrl)
      closeArticle()
      return
    }

    article = parsed
    articleState = ""
    flick.contentY = 0
  }

  // Tekst uit het script is platte tekst; voor de klikbare bronlinks bouwen we
  // er StyledText van. Het escapen gebeurt hier en niet in het script, zodat
  // de ontsnappingen bij de tekst blijven waar ze thuishoren.
  function esc(s) {
    return String(s === undefined || s === null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  function styled(runs) {
    if (!Array.isArray(runs)) return ""
    var out = ""
    for (var i = 0; i < runs.length; i++) {
      var r = runs[i] || {}
      var t = esc(r.x)
      if (r.h) {
        // Onderstreept in plaats van een andere kleur: dit thema heeft geen
        // linkkleur, en `accent` is hier dezelfde tint als de voorgrond.
        out += '<a href="' + esc(r.h) + '"><u>' + t + "</u></a>"
      } else {
        out += t
      }
    }
    return out
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }
  }

  Process {
    id: sourcesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySources(text)
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySet(text)
    }
  }

  Process {
    id: manageProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyManage(text)
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySearch(text)
    }
  }

  Process {
    id: articleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyArticle(text)
    }
  }

  Timer {
    id: articleGuard
    interval: 12000
    running: root.articleMode && root.articleState === "bezig"
    onTriggered: root.articleTimeout()
  }

  Process {
    id: archiveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyArchive(text)
    }
  }

  // Bevestiging "opgeslagen in artikel-archief.md" tijdelijk tonen.
  Timer {
    id: archiveMsgTimer
    interval: 3000
    onTriggered: root.archiveMsg = ""
  }

  Process {
    id: prikProc
    onExited: {
      root.prikBusy = false
      root.runNextPrik()
    }
  }

  Process {
    id: toastProc
    running: false
  }

  Timer {
    id: prikTimer
    interval: root.prikIntervalMs
    repeat: true
    onTriggered: root.pollKops()
  }

  Timer {
    id: prikStartTimer
    interval: 20000
    repeat: false
    onTriggered: root.pollKops()
  }

  Component.onCompleted: {
    prikStartTimer.start()
    prikTimer.start()
  }

  onOpenedChanged: {
    hoveredIndex = -1
    if (!opened) return
    // De bronnenlijst verandert zelden; een keer per shell sessie ophalen is
    // genoeg en houdt het openen van het paneel snel.
    if (!sources.length) {
      sourcesProc.command = [scriptPath, "sources"]
      sourcesProc.running = true
    }
    refresh()
  }

  readonly property string tooltipSummary: {
    var name = activeSource && activeSource.name ? activeSource.name : "nieuws"
    return items.length ? name + " — " + items.length + " koppen" : name
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.tooltipSummary
    active: root.fetchState === "fout"

    // Eigen icoontje, getekend met vlakken in plaats van een glyph of een
    // SVG. Reden: `Text.Svg` bestaat niet in deze QML-build (de enum is
    // undefined, waarna de hele SVG-markup als letterreeks in de balk
    // verscheen), en een materiaal-glyph loopt op 16px dicht met dunne
    // lijnen. Een omgetekende pagina met een kopbalk en twee regels blijft
    // leesbaar, volgt het thema en tekent overal hetzelfde af.
    iconComponent: Component {
      Item {
        id: mark
        // Vaste bronmaat: de balk schaalt de getekende omtrek naar zijn eigen
        // icon-size. anchors.fill werkt hier niet, want de loader die dit
        // component laadt heeft zelf geen afmeting; de vlakken werden dan
        // 0px en het icoon bleef onzichtbaar.
        width: 24
        height: 24
        readonly property real s: width / 24
        readonly property color ink: button.active && button.useActiveColor
          ? button.activeColor : button.foreground

        Rectangle {
          x: 2.8 * mark.s
          y: 2.8 * mark.s
          width: 18.4 * mark.s
          height: 18.4 * mark.s
          radius: 1.8 * mark.s
          color: "transparent"
          border.width: Math.max(1, Math.round(1.8 * mark.s))
          border.color: mark.ink
        }

        Rectangle {
          x: 6.6 * mark.s
          y: 6.6 * mark.s
          width: 10.8 * mark.s
          height: 2.6 * mark.s
          color: mark.ink
        }

        Rectangle {
          x: 6.6 * mark.s
          y: 11.2 * mark.s
          width: 10.8 * mark.s
          height: 1.9 * mark.s
          color: mark.ink
        }

        Rectangle {
          x: 6.6 * mark.s
          y: 14.8 * mark.s
          width: 10.8 * mark.s
          height: 1.9 * mark.s
          color: mark.ink
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.refresh()
        return
      }
      if (b === Qt.RightButton) {
        if (root.bar && root.activeSource && root.activeSource.site) {
          root.bar.run("omarchy-launch-browser " + root.activeSource.site)
        }
        return
      }
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Iets breder in de artikelweergave: een alinea die over drie regels
    // uitloopt is lastiger te lezen dan een die er twee gebruikt.
    contentWidth: panel.fittedContentWidth(Style.space(root.articleMode ? 520 : 440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Zolang een tekstveld focus heeft, wil het alle toetsen: een "b" die
      // de bron "tweakers" verandert in "tweakersb" is geen navigatie maar
      // een typefout. De esc en enter uit dit blok horen dan bij het veld.
      blocked: editor.activeFocus || menuValueField.activeFocus || menuNameField.activeFocus || menuSearchField.activeFocus

      Keys.onPressed: function(event) {
        if (root.articleMode && !keyCatcher.blocked) {
          if (event.key === Qt.Key_X || event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) {
            root.articleFontDelta = Math.min(12, root.articleFontDelta + 1)
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Z || event.key === Qt.Key_Minus) {
            root.articleFontDelta = Math.max(-2, root.articleFontDelta - 1)
            event.accepted = true
            return
          }
        }
      }

      onMoveRequested: function(dx, dy) {
        // Pijltjes links/rechts: in een artikel blader je door de lijst, in
        // het menu door de bronrijen, daarbuiten over de topbalk en door
        // het hamburgermenu (rechts na de laatste tab, of terug vanaf het
        // begin). Omhoog/omlaag scrollt of beweegt de menucursor.
        if (dy === 0) {
          if (root.articleMode) {
            // Links gaat terug naar de koppen, rechts naar het volgende
            // artikel. Zo hoef je voor terug niet naar esc te zoeken.
            if (dx < 0) { root.backFromArticle(); return }
            if (root.articleIndex >= 0 && root.items.length) {
              var na = (root.articleIndex + 1) % root.items.length
              root.showArticle(na)
            }
            return
          }
          if (root.menuMode) {
            // Links verlaat het menu terug naar de koppen; rechts opent de
            // gemarkeerde bron. Omhoog/omlaag lopen door de bronrijen.
            if (dx < 0) { root.toggleMenu(); return }
            if (root.menuFormMode === "") {
              var mn = root.menuCursor < 0 ? root.sourceIndex : root.menuCursor
              root.menuOpen(mn)
            }
            return
          }
          root.topArrow(dx > 0 ? 1 : -1)
          return
        }
        if (root.menuMode && root.menuFormMode === "") {
          root.menuArrow(dy > 0 ? 1 : -1)
          return
        }
        if (!root.articleMode && !root.menuMode) {
          root.listArrow(dy > 0 ? 1 : -1)
          return
        }
        var max = Math.max(0, flick.contentHeight - flick.height)
        flick.contentY = Math.max(0, Math.min(flick.contentY + dy * Style.space(48), max))
      }

      // Enter bevestigt wat onder de cursor zit: een formulier slaat op, een
      // menurij wordt de te bekijken bron, in een artikel gaat de browser
      // open. Met een geopend tekstveld is de catcher geblokkeerd en doet
      // het veld zelf (Opslaan bij onAccepted) dat al.
      onActivateRequested: function() {
        if (root.editing) { root.saveEdit(); return }
        if (root.menuMode) {
          if (root.menuFormMode !== "") { root.menuSave(); return }
          if (root.menuCursor >= 0) { root.menuOpen(root.menuCursor); return }
          return
        }
        if (!root.articleMode && root.listCursor >= 0 && root.listCursor < root.items.length) {
          root.showArticle(root.listCursor)
          return
        }
        if (root.articleMode) { root.openArticle(root.articleIndex); return }
      }

      onCloseRequested: root.goBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // Backspace laat Qt een "\b" zien en PanelKeyCatcher stuurt die
        // gewoon door als tekst, dus vangen we hem hier op.
        if (t === "\b" || t === "b" || t === "B") {
          root.goBack()
          return
        }
        if (t === "r" || t === "R") {
          if (root.articleMode) {
            root.showArticle(root.articleIndex)
          } else {
            root.refresh()
          }
          return
        }
        if (t === "o" || t === "O") {
          if (root.bar && root.activeSource && root.activeSource.site) {
            root.bar.run("omarchy-launch-browser " + root.activeSource.site)
          }
          return
        }
        if (t === "e" || t === "E") {
          if (!root.menuMode) root.startEdit()
          return
        }
        if (t === "s" || t === "S") {
          if (root.articleMode) { root.saveCurrentArticle(); return }
        }
        if (t === "z" || t === "Z" || t === "-") {
          if (root.articleMode) { root.articleFontDelta = Math.max(-2, root.articleFontDelta - 1); return }
        }
        if (t === "x" || t === "X" || t === "+" || t === "=") {
          if (root.articleMode) { root.articleFontDelta = Math.min(12, root.articleFontDelta + 1); return }
        }
        if (t === "a" || t === "A") {
          if (root.menuMode) {
            root.menuAddMode()
            return
          }
        }

        if (root.menuMode) {
          // In het menu wisselt een cijfer naar die bron; de koppen komen
          // vanzelf tevoorschijn zodra het menu dicht is.
          var n = parseInt(t, 10)
          if (!isNaN(n) && n >= 1 && n <= root.sources.length) {
            root.menuOpen(n - 1)
          }
          return
        }
        n = parseInt(t, 10)
        if (!isNaN(n) && n >= 1 && n <= root.items.length) {
          if (root.articleMode) {
            root.closeArticle()
          }
          root.showArticle(n - 1)
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(2)

          // -------------------------------------------- bron bewerken
          // Alleen zichtbaar tijdens het bewerken. Verschijnt het pas
          // nadat je op e hebt gedrukt, dan schuift de lijst niet weg
          // zonder dat je erom vraagt.
          Item {
            width: parent.width
            height: editor.implicitHeight + Style.space(12)
            visible: root.editing

            Text {
              id: editLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.activeSource && root.activeSource.key === "youtube"
                ? "kanaal" : "feed"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.captionFont
            }

            TextField {
              id: editor
              anchors.left: editLabel.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              text: root.editValue
              placeholderText: root.activeSource && root.activeSource.key === "youtube"
                ? "@kanaalnaam" : "https://…/feed.xml"
              foreground: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.bodyFont
              horizontalPadding: Style.spacing.controlGap
              verticalPadding: Style.spacing.controlPaddingY

              // Zonder dit zou de waarde bij elke toets in het model
              // terugschrijven en de cursor naar het einde springen.
              onTextChanged: if (text !== root.editValue) root.editValue = text

              onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
              onAccepted: root.saveEdit()

              // Enter en escape worden door het blok niet meer onderschept,
              // dus ze komen hier terecht.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelEdit()
                  event.accepted = true
                }
              }

              Behavior on opacity {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
              }
              opacity: root.editState === "bezig" ? 0.5 : 1
            }
          }

          // ------------------------------------------------ brontabs
          // Vervangt de oude vaste kop. De tabs blijven ook staan als je een
          // artikel leest, zodat je ziet van welke bron je leest en zo nodig
          // meteen kunt wisselen.
          Item {
            id: sourceBar
            width: parent.width
            height: tabRow.implicitHeight + Style.space(14)
            visible: root.sources.length > 0

            Row {
              id: tabRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Repeater {
                model: root.tabModel

                delegate: Item {
                  id: tab
                  required property var modelData
                  required property int index

                  readonly property int sourceIndex: tab.modelData.index
                  readonly property bool activeTab: root.sourceIndex === sourceIndex

                  width: tabLabel.implicitWidth
                  height: tabLabel.implicitHeight + Style.space(3)

                  Text {
                    id: tabLabel
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: tab.modelData.name || ""
                    color: tab.activeTab ? root.barForeground : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    font.weight: tab.activeTab ? Font.DemiBold : Font.Normal
                  }

                  // Onderstreping in plaats van een kleurverschil: het thema
                  // heeft geen accentkleur die hier betekenis zou krijgen.
                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: tabLabel.implicitWidth
                    height: Math.max(1, Math.round(Style.space(1)))
                    color: root.barForeground
                    visible: tab.activeTab
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.menuMode ? root.menuOpen(sourceIndex) : root.setSource(sourceIndex)
                  }
                }
              }
            }

            Text {
              anchors.right: menuBtn.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.fetchState === "bezig" ? "laden…"
                : root.items.length ? "1–" + root.items.length + " om te lezen"
                : "r = verversen"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.captionFont
            }

            // Hamburger voor bronbeheer: toevoegen, bewerken, verplaatsen en
            // verwijderen van bronnen. Rechts, als tegenhanger van de tabs.
            Item {
              id: menuBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18)
              height: Style.space(14)

              Repeater {
                model: 3
                Rectangle {
                  x: 0
                  width: parent.width
                  height: Math.max(1, Math.round(Style.space(2)))
                  radius: height / 2
                  color: menuHover.containsMouse ? root.barForeground : Color.muted
                  y: index * Style.space(5)
                }
              }

              MouseArea {
                id: menuHover
                // Boven de streepjes van de Repeater, anders vangt een streep
                // de hover op en reageert alleen de rand van het icoon.
                z: 2
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleMenu()
              }
            }
          }

          // ---------------------------------------------- bronbeheer
          // De weergave die het hamburger-menu opent: elke bron op een rij
          // met verplaatsen en verwijderen, en een formulier voor een
          // nieuwe of te bewerken bron.
          Column {
            id: menuCol
            width: parent.width
            visible: root.menuMode
            spacing: Style.space(6)

            Row {
              width: parent.width

              Text {
                id: backBtn
                width: Style.space(16)
                height: Style.space(16)
                text: "\u2190"
                color: backHover.containsMouse ? root.barForeground : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.bodyFont
                verticalAlignment: Text.AlignVCenter
                topPadding: Style.space(2)

                MouseArea {
                  id: backHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleMenu()
                }
              }

              Text {
                width: parent.width - Style.space(16) - addBtn.implicitWidth
                  - archieBtn.implicitWidth - Style.space(16)
                text: "bronnen (" + root.sources.length + ")"
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.captionFont
                verticalAlignment: Text.AlignVCenter
                topPadding: Style.space(2)
              }

              Text {
                id: addBtn
                height: Style.space(16)
                text: "nieuw"
                color: addHover.containsMouse ? root.barForeground : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.captionFont
                verticalAlignment: Text.AlignVCenter
                topPadding: Style.space(2)

                MouseArea {
                  id: addHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.menuAddMode()
                }
              }

              Text {
                id: archieBtn
                height: Style.space(16)
                text: "archief"
                color: archieHover.containsMouse ? root.barForeground : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.captionFont
                verticalAlignment: Text.AlignVCenter
                topPadding: Style.space(2)

                MouseArea {
                  id: archieHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.menuArchiveMode()
                }
              }
            }

            Repeater {
              id: menuRows
              model: root.sources

              delegate: Rectangle {
                id: mrow
                required property var modelData
                required property int index

                width: parent.width
                height: Math.max(msel.implicitHeight, mrowBtns.implicitHeight) + Style.space(8)
                radius: Style.cornerRadius
                color: mrowHover.hovered || root.menuCursor === mrow.index
                  ? Color.menu.selectedBackground : "transparent"

                HoverHandler {
                  id: mrowHover
                }

                Column {
                  id: msel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(88)
                  anchors.leftMargin: Style.space(8)
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: (mrow.index + 1) + ".  " + (mrow.modelData.name || "naamloos")
                    color: root.barForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    font.weight: mrow.index === root.sourceIndex ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: mrow.modelData.value || mrow.modelData.site || ""
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.captionFont
                    elide: Text.ElideRight
                    topPadding: Style.space(1)
                  }
                }

                Row {
                  id: mrowBtns
                  // Boven mrowMouse leggen, anders vangt de rij-klik (bewerken)
                  // alle toetsen op en werken ×/↑/↓ nooit.
                  z: 2
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    text: "\u270e"
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    color: medit.containsMouse ? root.barForeground : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    MouseArea {
                      id: medit
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.menuEdit(mrow.index)
                    }
                  }

                  Text {
                    text: "↑"
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    color: mup.containsMouse ? root.barForeground : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    enabled: mrow.index > 0
                    opacity: mrow.index > 0 ? 1 : 0.3
                    MouseArea {
                      id: mup
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.manage("move", [String(mrow.index), String(mrow.index - 1)])
                    }
                  }

                  Text {
                    text: "↓"
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    color: mdown.containsMouse ? root.barForeground : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    enabled: mrow.index < root.sources.length - 1
                    opacity: mrow.index < root.sources.length - 1 ? 1 : 0.3
                    MouseArea {
                      id: mdown
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.manage("move", [String(mrow.index), String(mrow.index + 1)])
                    }
                  }

                  Text {
                    text: "×"
                    width: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    color: mdel.containsMouse ? Color.urgent : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    MouseArea {
                      id: mdel
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.manage("remove", [String(mrow.index)])
                    }
                  }
                }

                MouseArea {
                  id: mrowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.menuOpen(mrow.index)
                }
              }
            }

            // Formulier voor een nieuwe of te bewerken bron.
            Item {
              width: parent.width
              visible: root.menuFormMode !== ""
              height: visible ? formCol.implicitHeight : 0

              Column {
                id: formCol
                width: parent.width
                spacing: Style.space(6)

                Text {
                  id: menuTitle
                  width: parent.width
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.bodyFont
                  font.weight: Font.DemiBold
                  color: root.barForeground
                  topPadding: Style.space(4)
                }

                Row {
                  width: parent.width
                  visible: root.menuFormMode !== "archief"
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(52)
                    text: "waarde"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.captionFont
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  TextField {
                    id: menuValueField
                    width: parent.width - Style.space(60)
                    placeholderText: "@kanaal of https://…/feed.xml"
                    foreground: root.barForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY

                    onAccepted: root.menuSave()
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.goBack()
                        event.accepted = true
                      }
                    }
                  }
                }

                Row {
                  width: parent.width
                  visible: root.menuFormMode !== "archief"
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(52)
                    text: "naam"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.captionFont
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  TextField {
                    id: menuNameField
                    width: parent.width - Style.space(60)
                    placeholderText: "optioneel; anders de feedtitel"
                    foreground: root.barForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.bodyFont
                    horizontalPadding: Style.spacing.controlGap
                    verticalPadding: Style.spacing.controlPaddingY

                    onAccepted: root.menuSave()
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) {
                        root.goBack()
                        event.accepted = true
                      }
                    }
                  }
                }

                // Kanaal zoeken op YouTube (nieuwe bron) of zoekopdracht in
                // het artikel-archief; een term typen en op Enter drukken
                // vult de resultaten eronder.
                Item {
                  width: parent.width
                  visible: root.menuFormMode === "add" || root.menuFormMode === "archief"
                  height: visible ? searchHead.implicitHeight : 0

                  Row {
                    id: searchHead
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      width: Style.space(52)
                      text: "zoek"
                      color: Color.muted
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.captionFont
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    TextField {
                      id: menuSearchField
                      width: parent.width - Style.space(60)
                      placeholderText: root.menuFormMode === "archief"
                        ? "filter het archief, of leeg voor alles"
                        : "typ een YouTube-kanaal of een domein (bv. ad.nl) en druk Enter"
                      foreground: root.barForeground
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.bodyFont
                      horizontalPadding: Style.spacing.controlGap
                      verticalPadding: Style.spacing.controlPaddingY

                      onAccepted: root.menuFormMode === "archief" ? root.runArchiveSearch() : root.startSearch()
                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                          root.goBack()
                          event.accepted = true
                        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
                          var maxY = Math.max(0, flick.contentHeight - flick.height)
                          var step = event.key === Qt.Key_Down ? 1 : -1
                          flick.contentY = Math.max(0, Math.min(maxY, flick.contentY + step * Style.space(48)))
                          event.accepted = true
                        }
                      }
                    }
                  }
                }

                // Status + resultaten van de zoekopdracht.
                Item {
                  width: parent.width
                  visible: (root.menuFormMode === "add" || root.menuFormMode === "archief") &&
                           (root.searching || root.searchResults.length > 0 || root.searchError !== "" ||
                            root.archiveSearching || root.archiveResults.length > 0 || root.archiveError !== "")
                  height: visible ? searchResultCol.implicitHeight : 0

                  Column {
                    id: searchResultCol
                    width: parent.width
                    spacing: Style.space(4)

                    Text {
                      width: parent.width
                      visible: root.searching || (root.menuFormMode === "archief" && root.archiveSearching)
                      text: "bezig met zoeken \u2026"
                      color: Color.muted
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.captionFont
                    }

                    Text {
                      width: parent.width
                      visible: root.menuFormMode === "archief"
                        ? !root.archiveSearching && root.archiveResults.length === 0 && root.archiveError !== ""
                        : !root.searching && root.searchResults.length === 0 && root.searchError !== ""
                      text: root.menuFormMode === "archief" ? root.archiveError : root.searchError
                      textFormat: Text.PlainText
                      color: Color.urgent
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: root.captionFont
                      wrapMode: Text.WordWrap
                    }

                    Repeater {
                      model: root.searchResults

                      delegate: Rectangle {
                        required property var modelData
                        required property int index

                        visible: root.menuFormMode === "add"

                        readonly property bool srFeed: modelData.kind === "feed"
                        readonly property string srName: String(modelData.name || "")
                        readonly property string srHandle: String(modelData.handle || "")
                        readonly property string srSubs: String(modelData.subscribers || "")
                        readonly property string srValue: String(modelData.value || "")
                        readonly property string srSample: {
                          if (!modelData.sample || !Array.isArray(modelData.sample)) return ""
                          return modelData.sample.join(" \u00b7 ")
                        }

                        width: parent.width
                        height: srText.implicitHeight + (srSample === "" ? Style.space(8) : srSampleText.implicitHeight + Style.space(12))
                        radius: Style.cornerRadius
                        color: srHover.containsMouse ? Color.menu.selectedBackground : "transparent"

                        Text {
                          id: srText
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.top: parent.top
                          anchors.leftMargin: Style.space(4)
                          anchors.rightMargin: Style.space(8)
                          anchors.topMargin: srSample === "" ? Style.space(4) : Style.space(3)
                          elide: Text.ElideRight
                          color: root.barForeground
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: root.captionFont
                          text: {
                            if (srFeed) {
                              var note = String(modelData.note || "")
                              return srName + (note !== "" ? "  (" + note + ")" : "")
                            }
                            var bits = [srName, srHandle]
                            if (srSubs !== "") bits.push("(" + srSubs + ")")
                            return bits.join("  ")
                          }
                        }

                        Text {
                          id: srSampleText
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.top: srText.bottom
                          anchors.leftMargin: Style.space(4)
                          anchors.rightMargin: Style.space(8)
                          anchors.topMargin: Style.space(2)
                          visible: srSample !== ""
                          elide: Text.ElideRight
                          color: Color.muted
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: root.captionFont
                          text: srSample
                        }

                        MouseArea {
                          id: srHover
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (srFeed) {
                              if (srValue === "") return
                              root.manage("add", [srValue, srName])
                              return
                            }
                            if (srHandle === "") return
                            root.manage("add", ["@" + srHandle.replace(/^@/, ""), srName])
                          }
                        }
                      }
                    }
                  }
                }

                // Resultaten van het archief-zoeken: titel onder datumbalk,
                // klikken opent het artikel.
                Item {
                  width: parent.width
                  visible: root.menuFormMode === "archief"
                  height: visible ? archiefCol.implicitHeight : 0

                  Column {
                    id: archiefCol
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                      model: root.archiveResults

                      delegate: Rectangle {
                        required property var modelData
                        required property int index

                        readonly property string arTitle: String(modelData.titel || "zonder titel")
                        readonly property string arDate: String(modelData.datum || "")
                        readonly property string arSnippet: String(modelData.snippet || "")

                        width: parent.width
                        height: arText.implicitHeight + (arDate === "" ? Style.space(8) : arDateText.implicitHeight + Style.space(10))
                        radius: Style.cornerRadius
                        color: arRowHover.hovered ? Color.menu.selectedBackground : "transparent"

                        HoverHandler {
                          id: arRowHover
                        }

                        Column {
                          anchors.left: parent.left
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                          anchors.leftMargin: Style.space(4)
                          anchors.rightMargin: Style.space(26)
                          spacing: Style.space(1)

                          Text {
                            id: arText
                            width: parent.width
                            elide: Text.ElideRight
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: root.bodyFont
                            text: arTitle
                          }

                          Text {
                            id: arDateText
                            width: parent.width
                            visible: arDate !== ""
                            elide: Text.ElideRight
                            color: Color.muted
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: root.captionFont
                            text: arDate
                          }

                          Text {
                            width: parent.width
                            visible: arSnippet !== ""
                            elide: Text.ElideRight
                            color: Color.muted
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: root.captionFont
                            text: arSnippet
                          }
                        }

                        MouseArea {
                          id: arHover
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.openArchiveResult(index)
                        }

                        // Extern openen: hetzelfde artikel in de browser, naast
                        // de rij-klik die het in het paneel leest.
                        Text {
                          z: 2
                          anchors.right: parent.right
                          anchors.rightMargin: Style.space(6)
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(16)
                          horizontalAlignment: Text.AlignHCenter
                          text: "\u2197"
                          color: arOpenHover.containsMouse ? root.barForeground : Color.muted
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: root.bodyFont

                          MouseArea {
                            id: arOpenHover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.openArchiveExternal(index)
                          }
                        }
                      }
                    }
                  }
                }

                Row {
                  width: parent.width
                  visible: root.menuFormMode !== "archief"
                  spacing: Style.space(12)

                  Text {
                    text: root.menuFormMode === "add" ? "toevoegen" : "opslaan"
                    color: root.barForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.captionFont
                    font.weight: Font.DemiBold
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.menuSave()
                    }
                  }

                  Text {
                    text: "annuleren"
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: root.captionFont
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.menuFormMode = ""
                        root.manageError = ""
                        root.resetSearch()
                        root.blurMenu()
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: root.manageError !== ""
                  text: root.manageError
                  textFormat: Text.PlainText
                  color: Color.urgent
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.captionFont
                  wrapMode: Text.WordWrap
                }
              }
            }

            Text {
              width: parent.width
              visible: root.menuFormMode === ""
              text: "klik op een bron om te bekijken \u00b7 \u270e bewerken \u00b7 \u2191 \u2193 verplaatsen \u00b7 \u00d7 verwijderen \u00b7 a = nieuwe bron"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.captionFont
              wrapMode: Text.WordWrap
              topPadding: Style.space(2)
            }
          }

          // ------------------------------------------------------ nieuws
          Repeater {
            id: newsRows
            model: root.items

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index

              visible: !root.articleMode && !root.menuMode

              readonly property bool expanded: (root.hoveredIndex === row.index || root.listCursor === row.index)
                && (row.modelData.lead || "") !== ""
              readonly property string metaText: {
                var bits = []
                if (row.modelData.author) bits.push(row.modelData.author)
                if (row.modelData.date) bits.push(row.modelData.date)
                return bits.join(" \u00b7 ")
              }

              width: column.width
              height: rowTitle.implicitHeight + Style.space(12) + (row.expanded ? rowDetail.implicitHeight + Style.space(10) : 0)
              radius: Style.cornerRadius
              color: rowHover.containsMouse || root.listCursor === row.index
                ? Color.menu.selectedBackground : "transparent"

              Behavior on height {
                NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
              }

              // Het nummer blijft bovenaan staan als het blok eronder uitklapt,
              // anders zou het meebewegen en de rij opleveren.
              Rectangle {
                id: numberBox
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.topMargin: Style.space(6)
                width: Style.space(18)
                height: Style.space(18)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Color.menu.border

                Text {
                  anchors.centerIn: parent
                  text: String(row.index + 1)
                  color: rowHover.containsMouse || root.listCursor === row.index
                    ? root.barForeground : Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.captionFont
                }
              }

              Text {
                id: rowTitle
                anchors.left: numberBox.right
                anchors.right: parent.right
                anchors.rightMargin: root.isYoutube ? Style.space(56) : 0
                anchors.top: parent.top
                anchors.topMargin: Style.space(6)
                anchors.leftMargin: Style.space(10)
                text: row.modelData.title
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.bodyFont
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              // Bij een youtube-bron: een linkje dat de videopagina in de
              // browser opent. Boven rowHover leggen, anders kaapt de klik
              // van het artikel die actie af.
              Text {
                id: vidLink
                visible: root.isYoutube
                z: 2
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                text: "\u25b6 video"
                color: vidLinkHover.containsMouse ? root.barForeground : Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.captionFont
                elide: Text.ElideRight

                MouseArea {
                  id: vidLinkHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (row.modelData.url) Qt.openUrlExternally(row.modelData.url)
                  }
                }
              }

              Column {
                id: rowDetail
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: rowTitle.bottom
                anchors.topMargin: Style.space(6)
                anchors.leftMargin: Style.space(28)
                spacing: Style.space(4)
                visible: row.expanded
                opacity: row.expanded ? 1 : 0

                Behavior on opacity {
                  NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                }

                Text {
                  width: parent.width
                  text: row.modelData.lead
                  color: Color.muted
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.captionFont
                  wrapMode: Text.WordWrap
                  maximumLineCount: 5
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: row.metaText + (row.modelData.reacties ? "   \u00b7   " + row.modelData.reacties + " reacties" : "")
                  color: Color.muted
                  opacity: 0.7
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: root.captionFont
                  wrapMode: Text.WordWrap
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: rowHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: root.hoveredIndex = row.index
                onExited: if (root.hoveredIndex === row.index) root.hoveredIndex = -1
                onClicked: function(mouse) {
                  // Rechtsklik blijft de directe route naar de browser.
                  if (mouse.button === Qt.RightButton) {
                    root.openArticle(row.index)
                    return
                  }
                  root.showArticle(row.index)
                }
              }
            }
          }

          // Niets te tonen: het paneel zou anders een lege doos zijn, en een
          // lege doos zonder uitleg leest als een bug.
          Column {
            width: parent.width
            visible: !root.articleMode && !root.menuMode && root.fetchState !== "bezig" && root.items.length === 0
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: root.fetchState === "fout" ? root.message : "Geen koppen gevonden"
              color: root.fetchState === "fout" ? Color.urgent : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.bodyFont
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "druk op r om opnieuw te proberen"
              color: Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.captionFont
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            visible: root.editError !== ""
            text: root.editError
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.captionFont
            wrapMode: Text.WordWrap
            topPadding: Style.space(4)
          }

          Text {
            width: parent.width
            visible: !root.articleMode && !root.menuMode && root.items.length > 0 && !root.editing
            text: root.sources.length > 1
              ? "\u2191\u2193 = kies kop \u00b7 enter = lezen \u00b7 \u2190 \u2192 = andere bron \u00b7 e = bron bewerken \u00b7 r = verversen"
              : "\u2191\u2193 = kies kop \u00b7 enter = lezen \u00b7 e = bron bewerken \u00b7 r = verversen"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.captionFont
            wrapMode: Text.WordWrap
            topPadding: Style.space(2)
          }

          Text {
            width: parent.width
            visible: root.editing
            text: "enter = opslaan \u00b7 esc = annuleren \u00b7 schrijft naar sources.json"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.captionFont
            wrapMode: Text.WordWrap
            topPadding: Style.space(4)
          }

          Text {
            id: articleTitle
            width: parent.width
            visible: root.articleMode && root.article !== null
            text: root.article ? root.article.title : ""
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.articleTitleFont
            wrapMode: Text.WordWrap
            topPadding: Style.space(10)
            bottomPadding: Style.space(4)
          }

          Text {
            width: parent.width
            visible: root.articleMode && root.article !== null && text !== ""
            text: {
              if (!root.article) return ""
              var bits = []
              if (root.article.author) bits.push(root.article.author)
              if (root.article.date) bits.push(root.article.date)
              if (root.article.reacties) bits.push(root.article.reacties + " reacties")
              return bits.join(" \u00b7 ")
            }
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.articleTextFont
            wrapMode: Text.WordWrap
            bottomPadding: Style.space(10)
          }

          Item {
            width: parent.width
            visible: root.articleMode && root.article !== null
            height: fontRow.implicitHeight + Style.space(10)

            Row {
              id: fontRow
              spacing: Style.space(12)

              Text {
                text: "A-"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.bodyFont
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.articleFontDelta = Math.max(-2, root.articleFontDelta - 1)
                }
              }

              Text {
                text: "Lettergrootte " + (root.articleFontDelta > 0 ? "+" : "") + root.articleFontDelta + "  (z/x)"
                color: Color.muted
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.captionFont
              }

              Text {
                text: "A+"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: root.bodyFont
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.articleFontDelta = Math.min(12, root.articleFontDelta + 1)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.articleMode && root.article !== null
            text: "s = opslaan in archief \u00b7 z/x = lettergrootte \u00b7 \u2190 of esc = terug \u00b7 \u2192 = volgend artikel \u00b7 r = herladen"
            color: Color.muted
            opacity: 0.85
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.captionFont
            wrapMode: Text.WordWrap
            bottomPadding: Style.space(10)
          }

          Rectangle {
            width: parent.width
            visible: root.archiveMsg !== ""
            color: Color.menu.background
            border.color: Color.muted
            border.width: 1
            radius: Style.space(4)
            height: archiveMsgLabel.implicitHeight + Style.space(8)

            Text {
              id: archiveMsgLabel
              width: parent.width
              padding: Style.space(4)
              text: root.archiveMsg
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: root.bodyFont
              font.bold: true
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            visible: root.articleMode && root.article === null
            text: root.articleState === "fout" ? "kon het artikel niet ophalen" : "artikel laden…"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.bodyFont
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.article && Array.isArray(root.article.blocks) ? root.article.blocks : []

            delegate: Text {
              id: block
              required property var modelData

              readonly property string kind: block.modelData.t || "p"

              visible: root.articleMode

              x: (block.kind === "li" || block.kind === "quote") ? Style.space(14) : 0
              width: parent.width - x

              textFormat: Text.StyledText
              text: {
                var body = Array.isArray(block.modelData.r) && block.modelData.r.length
                  ? root.styled(block.modelData.r)
                  : root.esc(block.modelData.x)
                if (block.kind === "li") return "\u2022\u2003" + body
                if (block.kind === "quote") return "\u201c" + body + "\u201d"
                return body
              }

              onLinkActivated: function(href) {
                if (href) Qt.openUrlExternally(href)
              }

              color: root.barForeground
              opacity: block.kind === "lead" || block.kind === "h" ? 1
                : block.kind === "p" ? 0.88
                : block.kind === "li" ? 0.78
                : 0.68

              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: block.kind === "lead" || block.kind === "h" ? root.articleLeadFont : root.articleTextFont
              font.weight: block.kind === "h" ? Font.DemiBold : Font.Normal
              font.italic: block.kind === "quote"

              wrapMode: Text.WordWrap
              topPadding: block.kind === "h" ? Style.space(10)
                : block.kind === "p" ? Style.space(7)
                : block.kind === "quote" ? Style.space(5)
                : block.kind === "li" ? Style.space(1)
                : 0
            }
          }

          Text {
            width: parent.width
            visible: root.articleMode && root.article !== null
            text: "z/x = lettergrootte \u00b7 \u2190 of esc/backspace = terug \u00b7 \u2192 = volgend artikel \u00b7 r = herladen \u00b7 s = in archief"
            color: Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: root.articleTextFont
            wrapMode: Text.WordWrap
            topPadding: Style.space(12)
          }
        }
      }
    }
  }
}
