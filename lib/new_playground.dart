// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library new_playground;

import 'dart:async';
import 'dart:collection';
import 'dart:html' hide Console;

import 'package:logging/logging.dart';
import 'package:mdc_web/mdc_web.dart';
import 'package:meta/meta.dart';
import 'package:route_hierarchical/client.dart';
import 'package:split/split.dart';

import 'completion.dart';
import 'context.dart';
import 'core/dependencies.dart';
import 'core/keys.dart';
import 'core/modules.dart';
import 'dart_pad.dart';
import 'documentation.dart';
import 'editing/editor.dart';
import 'elements/bind.dart';
import 'elements/elements.dart';
import 'experimental/analysis_results_controller.dart';
import 'experimental/console.dart';
import 'experimental/counter.dart';
import 'experimental/dialog.dart';
import 'experimental/material_tab_controller.dart';
import 'modules/codemirror_module.dart';
import 'modules/dart_pad_module.dart';
import 'modules/dartservices_module.dart';
import 'playground_context.dart';
import 'services/_dartpadsupportservices.dart';
import 'services/common.dart';
import 'services/dartservices.dart';
import 'services/execution_iframe.dart';
import 'sharing/editor_doc_property.dart';
import 'sharing/gist_file_property.dart';
import 'sharing/gists.dart';
import 'sharing/gist_storage.dart';
import 'sharing/mutable_gist.dart';
import 'src/ga.dart';
import 'src/util.dart';
import 'util/detect_flutter.dart';

Playground get playground => _playground;

Playground _playground;

final Logger _logger = Logger('dartpad');

void init() {
  _playground = Playground();
}

class Playground implements GistContainer, GistController {
  final MutableGist editableGist = MutableGist(Gist());
  final GistStorage _gistStorage = GistStorage();
  MDCButton newButton;
  MDCButton resetButton;
  MDCButton formatButton;
  MDCButton samplesButton;
  MDCButton layoutsButton;
  MDCButton runButton;
  MDCButton editorConsoleTab;
  MDCButton editorDocsTab;
  MDCButton closePanelButton;
  MDCButton moreMenuButton;
  DElement editorPanelFooter;
  MDCMenu layoutMenu;
  MDCMenu samplesMenu;
  MDCMenu moreMenu;
  Dialog dialog;
  NewPadDialog newPadDialog;
  DElement titleElement;
  MaterialTabController webLayoutTabController;
  DElement webTabBar;

  Splitter splitter;
  Splitter rightSplitter;
  bool rightSplitterConfigured = false;
  TabExpandController tabExpandController;
  AnalysisResultsController analysisResultsController;

  DBusyLight busyLight;
  DBusyLight consoleBusyLight;

  Editor editor;
  PlaygroundContext _context;
  Future _analysisRequest;
  Layout _layout;

  // The last returned shared gist used to update the url.
  Gist _overrideNextRouteGist;
  DocHandler docHandler;

  Console _leftConsole;
  Console _rightConsole;
  Counter unreadConsoleCounter;

  Playground() {
    _initModules().then((_) {
      _initPlayground();
      _initDialogs();
      _initBusyLights();
      _initGistNameHeader();
      _initGistStorage();
      _initButtons();
      _initSamplesMenu();
      _initMoreMenu();
      _initLayoutMenu();
      _initSplitters();
      _initTabs();
      _initLayout();
      _initConsoles();
    });
  }

  DivElement get _editorHost => querySelector('#editor-host');
  DivElement get _rightConsoleElement => querySelector('#right-output-panel');
  DivElement get _leftConsoleElement => querySelector('#left-output-panel');
  IFrameElement get _frame => querySelector('#frame');
  DivElement get _rightDocPanel => querySelector('#right-doc-panel');
  DivElement get _leftDocPanel => querySelector('#left-doc-panel');
  DivElement get _editorPanelFooter => querySelector('#editor-panel-footer');
  bool get _isCompletionActive => editor.completionActive;

  void _initDialogs() {
    dialog = Dialog();
    newPadDialog = NewPadDialog();
  }

  void _initBusyLights() {
    busyLight = DBusyLight(querySelector('#dartbusy'));
    consoleBusyLight = DBusyLight(querySelector('#consolebusy'));
  }

  void _initGistNameHeader() {
    // Update the title on changes.
    titleElement = DElement(querySelector('header .header-gist-name'));
    bind(editableGist.property('description'), titleElement.textProperty);
  }

  void _initGistStorage() {
    // If there was a change, and the gist is dirty, write the gist's contents
    // to storage.
    debounceStream(mutableGist.onChanged, Duration(milliseconds: 100))
        .listen((_) {
      if (mutableGist.dirty) {
        _gistStorage.setStoredGist(mutableGist.createGist());
      }
    });
  }

  void _initButtons() {
    newButton = MDCButton(querySelector('#new-button'))
      ..onClick.listen((_) => _showCreateGistDialog());
    resetButton = MDCButton(querySelector('#reset-button'))
      ..onClick.listen((_) => _showResetDialog());
    formatButton = MDCButton(querySelector('#format-button'))
      ..onClick.listen((_) => _format());
    samplesButton = MDCButton(querySelector('#samples-dropdown-button'))
      ..onClick.listen((e) {
        samplesMenu.open = !samplesMenu.open;
      });

    layoutsButton = MDCButton(querySelector('#layout-menu-button'))
      ..onClick.listen((_) {
        layoutMenu.open = !layoutMenu.open;
      });

    runButton = MDCButton(querySelector('#run-button'))
      ..onClick.listen((_) {
        _handleRun();
      });
    editorConsoleTab = MDCButton(querySelector('#editor-panel-console-tab'));
    editorDocsTab = MDCButton(querySelector('#editor-panel-docs-tab'));
    closePanelButton =
        MDCButton(querySelector('#editor-panel-close-button'), isIcon: true);
    moreMenuButton = MDCButton(querySelector('#more-menu-button'), isIcon: true)
      ..onClick.listen((_) {
        moreMenu.open = !moreMenu.open;
      });
    querySelector('#keyboard-button')
        .onClick
        .listen((_) => _showKeyboardDialog());
  }

  void _initSamplesMenu() {
    var element = querySelector('#samples-menu');

    // Use SplayTreeMap to keep the order of the keys
    var samples = SplayTreeMap()
      ..addEntries([
        MapEntry('215ba63265350c02dfbd586dfd30b8c3', 'Hello World'),
        MapEntry('e93b969fed77325db0b848a85f1cf78e', 'Int to Double'),
        MapEntry('b60dc2fc7ea49acecb1fd2b57bf9be57', 'Mixins'),
        MapEntry('7d78af42d7b0aedfd92f00899f93561b', 'Fibonacci'),
        MapEntry('a559420eed617dab7a196b5ea0b64fba', 'Sunflower'),
        MapEntry('cb9b199b1085873de191e32a1dd5ca4f', 'WebSockets'),
      ]);

    var listElement = UListElement()
      ..classes.add('mdc-list')
      ..attributes.addAll({
        'aria-hidden': 'true',
        'aria-orientation': 'vertical',
        'tabindex': '-1'
      });

    element.children.add(listElement);

    // Helper function to create LIElement with correct attributes and classes
    // for material-components-web
    LIElement _menuElement(String gistId, String name) {
      return LIElement()
        ..classes.add('mdc-list-item')
        ..attributes.addAll({'role': 'menuitem'})
        ..children.add(
          SpanElement()
            ..classes.add('mdc-list-item__text')
            ..text = name,
        );
    }

    for (var gistId in samples.keys) {
      listElement.children.add(_menuElement(gistId, samples[gistId]));
    }

    samplesMenu = MDCMenu(element)
      ..setAnchorCorner(AnchorCorner.bottomLeft)
      ..setAnchorElement(querySelector('#samples-dropdown-button'))
      ..hoistMenuToBody();

    samplesMenu.listen('MDCMenu:selected', (e) {
      var index = (e as CustomEvent).detail['index'];
      var gistId = samples.keys.elementAt(index);
      router.go('gist', {'gist': gistId});
    });
  }

  void _initMoreMenu() {
    moreMenu = MDCMenu(querySelector('#more-menu'))
      ..setAnchorCorner(AnchorCorner.bottomLeft)
      ..setAnchorElement(querySelector('#more-menu-button'))
      ..hoistMenuToBody();
    moreMenu.listen('MDCMenu:selected', (e) {
      var idx = (e as CustomEvent).detail['index'];
      switch (idx) {
        case 0:
          _showSharingPage();
          break;
        case 1:
          _showGitHubPage();
          break;
      }
    });
  }

  void _initLayoutMenu() {
    layoutMenu = MDCMenu(querySelector('#layout-menu'))
      ..setAnchorCorner(AnchorCorner.bottomLeft)
      ..setAnchorElement(querySelector('#layout-menu-button'))
      ..hoistMenuToBody();
    layoutMenu.listen('MDCMenu:selected', (e) {
      var idx = (e as CustomEvent).detail['index'];
      switch (idx) {
        case 0:
          _changeLayout(Layout.dart);
          break;
        case 1:
          _changeLayout(Layout.web);
          break;
        case 2:
          _changeLayout(Layout.flutter);
          break;
      }
    });
  }

  void _initSplitters() {
    var editorPanel = querySelector('#editor-panel');
    var outputPanel = querySelector('#output-panel');

    splitter = flexSplit(
      [editorPanel, outputPanel],
      horizontal: true,
      gutterSize: 6,
      sizes: [50, 50],
      minSize: [100, 100],
    );
  }

  void _initRightSplitter() {
    if (rightSplitterConfigured) {
      return;
    }

    var outputHost = querySelector('#right-output-panel');
    rightSplitter = flexSplit(
      [outputHost, _rightDocPanel],
      horizontal: false,
      gutterSize: 6,
      sizes: [50, 50],
      minSize: [100, 100],
    );
    rightSplitterConfigured = true;
  }

  void _disposeRightSplitter() {
    if (!rightSplitterConfigured) {
      // The right splitter might already be destroyed.
      return;
    }
    rightSplitter?.destroy();
    rightSplitterConfigured = false;
  }

  void _initOutputPanelTabs() {
    if (tabExpandController != null) {
      return;
    }

    tabExpandController = TabExpandController(
      consoleButton: editorConsoleTab,
      docsButton: editorDocsTab,
      closeButton: closePanelButton,
      docsElement: _leftDocPanel,
      consoleElement: _leftConsoleElement,
      topSplit: _editorHost,
      bottomSplit: _editorPanelFooter,
      unreadCounter: unreadConsoleCounter,
    );
  }

  void _disposeOutputPanelTabs() {
    tabExpandController?.dispose();
    tabExpandController = null;
  }

  void _initTabs() {
    webTabBar = DElement(querySelector('#web-tab-bar'));
    webLayoutTabController =
        MaterialTabController(MDCTabBar(webTabBar.element));
    for (String name in ['dart', 'html', 'css']) {
      webLayoutTabController.registerTab(
          TabElement(querySelector('#$name-tab'), name: name, onSelect: () {
        ga.sendEvent('edit', name);
        _context.switchTo(name);
      }));
    }
  }

  void _initLayout() {
    editorPanelFooter = DElement(_editorPanelFooter);
    _changeLayout(Layout.dart);
  }

  void _initConsoles() {
    _leftConsole = Console(DElement(_leftConsoleElement));
    _rightConsole = Console(DElement(_rightConsoleElement));
    unreadConsoleCounter = Counter(querySelector('#unread-console-counter'));
  }

  Future _initModules() async {
    ModuleManager modules = ModuleManager();

    modules.register(DartPadModule());
    modules.register(DartServicesModule());
    modules.register(DartSupportServicesModule());
    modules.register(CodeMirrorModule());

    await modules.start();
  }

  void _initPlayground() {
    // Set up the iframe.
    deps[ExecutionService] = ExecutionServiceIFrame(_frame);
    executionService.onStdout.listen(_showOutput);
    executionService.onStderr.listen((m) => _showOutput(m, error: true));

    // Set up Google Analytics.
    deps[Analytics] = Analytics();

    // Set up the gist loader.
    deps[GistLoader] = GistLoader.defaultFilters();

    // Set up CodeMirror
    editor = editorFactory.createFromElement(_editorHost)
      ..theme = 'darkpad'
      ..mode = 'dart';

    // set up key bindings
    keys.bind(['ctrl-s'], _handleSave, 'Save', hidden: true);
    keys.bind(['ctrl-enter'], _handleRun, 'Run');
    keys.bind(['f1'], () {
      ga.sendEvent('main', 'help');
      docHandler.generateDoc(_rightDocPanel);
      docHandler.generateDoc(_leftDocPanel);
    }, 'Documentation');

    keys.bind(['alt-enter'], () {
      editor.showCompletions(onlyShowFixes: true);
    }, 'Quick fix');

    keys.bind(['ctrl-space', 'macctrl-space'], () {
      editor.showCompletions();
    }, 'Completion');

    keys.bind(['shift-ctrl-/', 'shift-macctrl-/'], () {
      _showKeyboardDialog();
    }, 'Shortcuts');

    document.onKeyUp.listen((e) {
      if (editor.completionActive ||
          DocHandler.cursorKeys.contains(e.keyCode)) {
        docHandler.generateDoc(_rightDocPanel);
        docHandler.generateDoc(_leftDocPanel);
      }
      _handleAutoCompletion(e);
    });

    _context = PlaygroundContext(editor);
    deps[Context] = _context;

    editorFactory.registerCompleter(
        'dart', DartCompleter(dartServices, _context.dartDocument));

    _context.onDartDirty.listen((_) => busyLight.on());
    _context.onDartReconcile.listen((_) => _performAnalysis());

    Property htmlFile =
        GistFileProperty(editableGist.getGistFile('index.html'));
    Property htmlDoc = EditorDocumentProperty(_context.htmlDocument, 'html');
    bind(htmlDoc, htmlFile);
    bind(htmlFile, htmlDoc);

    Property cssFile = GistFileProperty(editableGist.getGistFile('styles.css'));
    Property cssDoc = EditorDocumentProperty(_context.cssDocument, 'css');
    bind(cssDoc, cssFile);
    bind(cssFile, cssDoc);

    Property dartFile = GistFileProperty(editableGist.getGistFile('main.dart'));
    Property dartDoc = EditorDocumentProperty(_context.dartDocument, 'dart');
    bind(dartDoc, dartFile);
    bind(dartFile, dartDoc);

    // Listen for changes that would effect the documentation panel.
    editor.onMouseDown.listen((e) {
      // Delay to give codemirror time to process the mouse event.
      Timer.run(() {
        if (!_context.cursorPositionIsWhitespace()) {
          docHandler.generateDoc(_rightDocPanel);
          docHandler.generateDoc(_leftDocPanel);
        }
      });
    });

    // Set up the router.
    deps[Router] = Router();
    router.root.addRoute(name: 'home', defaultRoute: true, enter: showHome);
    router.root.addRoute(name: 'gist', path: '/:gist', enter: showGist);
    router.listen();

    docHandler = DocHandler(editor, _context);

    dartServices.version().then((VersionResponse version) {
      // "Based on Dart SDK 2.4.0"
      String versionText = 'Based on Dart SDK ${version.sdkVersionFull}';
      querySelector('#dartpad-version').text = versionText;
    }).catchError((e) => null);

    analysisResultsController = AnalysisResultsController(
        DElement(querySelector('#issues')),
        DElement(querySelector('#issues-message')),
        DElement(querySelector('#issues-toggle')))
      ..onIssueClick.listen((issue) {
        _jumpTo(issue.line, issue.charStart, issue.charLength, focus: true);
      });

    _finishedInit();
  }

  void _finishedInit() {
    // Clear the splash.
    DSplash splash = DSplash(querySelector('div.splash'));
    splash.hide();
  }

  final RegExp cssSymbolRegexp = RegExp(r'[A-Z]');

  void _handleAutoCompletion(KeyboardEvent e) {
    if (context.focusedEditor == 'dart' && editor.hasFocus) {
      if (e.keyCode == KeyCode.PERIOD) {
        editor.showCompletions(autoInvoked: true);
      }
    }

    if (!_isCompletionActive && editor.hasFocus) {
      if (context.focusedEditor == 'html') {
        if (printKeyEvent(e) == 'shift-,') {
          editor.showCompletions(autoInvoked: true);
        }
      } else if (context.focusedEditor == 'css') {
        if (cssSymbolRegexp.hasMatch(String.fromCharCode(e.keyCode))) {
          editor.showCompletions(autoInvoked: true);
        }
      }
    }
  }

  Future showHome(RouteEnterEvent event) async {
    // Don't auto-run if we're re-loading some unsaved edits; the gist might
    // have halting issues (#384).
    bool loadedFromSaved = false;
    Uri url = Uri.parse(window.location.toString());

    if (url.hasQuery &&
        url.queryParameters['id'] != null &&
        isLegalGistId(url.queryParameters['id'])) {
      _showGist(url.queryParameters['id']);
    } else if (url.hasQuery && url.queryParameters['export'] != null) {
      UuidContainer requestId = UuidContainer()
        ..uuid = url.queryParameters['export'];
      Future<PadSaveObject> exportPad =
          dartSupportServices.pullExportContent(requestId);
      await exportPad.then((pad) {
        Gist blankGist = createSampleGist();
        blankGist.getFile('main.dart').content = pad.dart;
        blankGist.getFile('index.html').content = pad.html;
        blankGist.getFile('styles.css').content = pad.css;
        editableGist.setBackingGist(blankGist);
      });
    } else if (url.hasQuery && url.queryParameters['source'] != null) {
      UuidContainer gistId = await dartSupportServices.retrieveGist(
          id: url.queryParameters['source']);
      Gist backing;

      try {
        backing = await gistLoader.loadGist(gistId.uuid);
      } catch (ex) {
        print(ex);
        backing = Gist();
      }

      editableGist.setBackingGist(backing);
      await router.go('gist', {'gist': backing.id});
    } else if (_gistStorage.hasStoredGist && _gistStorage.storedId == null) {
      loadedFromSaved = true;

      Gist blankGist = Gist();
      editableGist.setBackingGist(blankGist);

      Gist storedGist = _gistStorage.getStoredGist();
      editableGist.description = storedGist.description;
      for (GistFile file in storedGist.files) {
        editableGist.getGistFile(file.name).content = file.content;
      }
    } else {
      editableGist.setBackingGist(createSampleGist());
    }

    _clearOutput();

    _changeLayout(_detectLayout(editableGist.backingGist));

    // Analyze and run it.
    Timer.run(() {
      _performAnalysis().then((bool result) {
        // Only auto-run if the static analysis comes back clean.
        if (result && !loadedFromSaved) _handleRun();
        if (url.hasQuery && url.queryParameters['line'] != null) {
          _jumpToLine(int.parse(url.queryParameters['line']));
        }
      }).catchError((e) => null);
    });
  }

  void showGist(RouteEnterEvent event) {
    String gistId = event.parameters['gist'];

    _clearOutput();

    if (!isLegalGistId(gistId)) {
      showHome(event);
      return;
    }

    _showGist(gistId);
  }

  void _showGist(String gistId) {
    // Don't auto-run if we're re-loading some unsaved edits; the gist might
    // have halting issues (#384).
    bool loadedFromSaved = false;

    // When sharing, we have to pipe the returned (created) gist through the
    // routing library to update the url properly.
    if (_overrideNextRouteGist != null && _overrideNextRouteGist.id == gistId) {
      editableGist.setBackingGist(_overrideNextRouteGist);
      _overrideNextRouteGist = null;
      return;
    }

    _overrideNextRouteGist = null;

    gistLoader.loadGist(gistId).then((Gist gist) {
      editableGist.setBackingGist(gist);

      if (_gistStorage.hasStoredGist && _gistStorage.storedId == gistId) {
        loadedFromSaved = true;

        Gist storedGist = _gistStorage.getStoredGist();
        editableGist.description = storedGist.description;
        for (GistFile file in storedGist.files) {
          editableGist.getGistFile(file.name).content = file.content;
        }
      }

      _clearOutput();

      _changeLayout(_detectLayout(gist));

      // Analyze and run it.
      Timer.run(() {
        _performAnalysis().then((bool result) {
          // Only auto-run if the static analysis comes back clean.
          if (result && !loadedFromSaved) _handleRun();
        }).catchError((e) => null);
      });
    }).catchError((e) {
      String message = 'Error loading gist $gistId.';
      _showSnackbar(message);
      _logger.severe('$message: $e');
    });
  }

  void _showKeyboardDialog() {
    dialog.showOk('Keyboard shortcuts', keyMapToHtml(keys.inverseBindings));
  }

  void _handleRun() async {
    ga.sendEvent('main', 'run');
    runButton.disabled = true;

    Stopwatch compilationTimer = Stopwatch()..start();

    final CompileRequest compileRequest = CompileRequest()
      ..source = context.dartSource;

    try {
      if (hasFlutterContent(_context.dartSource)) {
        final CompileDDCResponse response = await dartServices
            .compileDDC(compileRequest)
            .timeout(longServiceCallTimeout);

        ga.sendTiming(
          'action-perf',
          'compilation-e2e',
          compilationTimer.elapsedMilliseconds,
        );

        _clearOutput();

        return executionService.execute(
          _context.htmlSource,
          _context.cssSource,
          response.result,
          modulesBaseUrl: response.modulesBaseUrl,
        );
      } else {
        final CompileResponse response = await dartServices
            .compile(compileRequest)
            .timeout(longServiceCallTimeout);

        ga.sendTiming(
          'action-perf',
          'compilation-e2e',
          compilationTimer.elapsedMilliseconds,
        );

        _clearOutput();

        return await executionService.execute(
          _context.htmlSource,
          _context.cssSource,
          response.result,
        );
      }
    } catch (e) {
      ga.sendException('${e.runtimeType}');
      final message = (e is DetailedApiRequestError) ? e.message : '$e';
      _showSnackbar('Error compiling to JavaScript');
      _showOutput('Error compiling to JavaScript:\n$message', error: true);
    } finally {
      runButton.disabled = false;
    }
  }

  /// Perform static analysis of the source code. Return whether the code
  /// analyzed cleanly (had no errors or warnings).
  Future<bool> _performAnalysis() {
    SourceRequest input = SourceRequest()..source = _context.dartSource;

    Lines lines = Lines(input.source);

    Future<AnalysisResults> request =
        dartServices.analyze(input).timeout(serviceCallTimeout);
    _analysisRequest = request;

    return request.then((AnalysisResults result) {
      // Discard if we requested another analysis.
      if (_analysisRequest != request) return false;

      // Discard if the document has been mutated since we requested analysis.
      if (input.source != _context.dartSource) return false;

      busyLight.reset();

      _displayIssues(result.issues);

      _context.dartDocument
          .setAnnotations(result.issues.map((AnalysisIssue issue) {
        int startLine = lines.getLineForOffset(issue.charStart);
        int endLine =
            lines.getLineForOffset(issue.charStart + issue.charLength);

        Position start = Position(
            startLine, issue.charStart - lines.offsetForLine(startLine));
        Position end = Position(
            endLine,
            issue.charStart +
                issue.charLength -
                lines.offsetForLine(startLine));

        return Annotation(issue.kind, issue.message, issue.line,
            start: start, end: end);
      }).toList());

      bool hasErrors = result.issues.any((issue) => issue.kind == 'error');
      bool hasWarnings = result.issues.any((issue) => issue.kind == 'warning');

      // TODO: show errors or warnings

      return hasErrors == false && hasWarnings == false;
    }).catchError((e) {
      _context.dartDocument.setAnnotations([]);
      busyLight.reset();
      _logger.severe(e);
    });
  }

  Future _format() {
    String originalSource = _context.dartSource;
    SourceRequest input = SourceRequest()..source = originalSource;
    formatButton.disabled = true;

    Future<FormatResponse> request =
        dartServices.format(input).timeout(serviceCallTimeout);
    return request.then((FormatResponse result) {
      busyLight.reset();
      formatButton.disabled = false;

      if (result.newString == null || result.newString.isEmpty) {
        _logger.fine('Format returned null/empty result');
        return;
      }

      if (originalSource != result.newString) {
        editor.document.updateValue(result.newString);
        _showSnackbar('Format successful.');
      } else {
        _showSnackbar('No formatting changes.');
      }
    }).catchError((e) {
      busyLight.reset();
      formatButton.disabled = false;
      _logger.severe(e);
    });
  }

  void _handleSave() => ga.sendEvent('main', 'save');

  void _clearOutput() {
    _rightConsole.clear();
    _leftConsole.clear();
    unreadConsoleCounter.clear();
  }

  void _showOutput(String message, {bool error = false}) {
    _leftConsole.showOutput(message, error: error);
    _rightConsole.showOutput(message, error: error);

    // If there's no tabs visible or the console is not being displayed,
    // increment the counter
    if (tabExpandController == null ||
        tabExpandController?.state != TabState.console) {
      unreadConsoleCounter.increment();
    }
  }

  void _showSnackbar(String message) {
    var div = querySelector('.mdc-snackbar');
    var snackbar = MDCSnackbar(div)..labelText = message;
    snackbar.open();
  }

  Layout _detectLayout(Gist gist) {
    if (gist.hasWebContent()) {
      return Layout.web;
    } else if (gist.hasFlutterContent()) {
      return Layout.flutter;
    } else {
      return Layout.dart;
    }
  }

  void _changeLayout(Layout layout) {
    if (_layout == layout) {
      return;
    }

    _layout = layout;

    var checkmarkIcons = [
      querySelector('#layout-dart-checkmark'),
      querySelector('#layout-web-checkmark'),
      querySelector('#layout-flutter-checkmark'),
    ];

    for (var checkmark in checkmarkIcons) {
      checkmark.classes.add('hide');
    }

    if (layout == Layout.dart) {
      _frame.hidden = true;
      editorPanelFooter.setAttr('hidden');
      _disposeOutputPanelTabs();
      _rightDocPanel.attributes.remove('hidden');
      _rightConsoleElement.attributes.remove('hidden');
      webTabBar.setAttr('hidden');
      webLayoutTabController.selectTab('dart');
      _initRightSplitter();
      checkmarkIcons[0].classes.remove('hide');
    } else if (layout == Layout.web) {
      _disposeRightSplitter();
      _frame.hidden = false;
      editorPanelFooter.clearAttr('hidden');
      _initOutputPanelTabs();
      _rightDocPanel.setAttribute('hidden', '');
      _rightConsoleElement.setAttribute('hidden', '');
      webTabBar.toggleAttr('hidden', false);
      webLayoutTabController.selectTab('dart');
      checkmarkIcons[1].classes.remove('hide');
    } else if (layout == Layout.flutter) {
      _disposeRightSplitter();
      _frame.hidden = false;
      editorPanelFooter.clearAttr('hidden');
      _initOutputPanelTabs();
      _rightDocPanel.setAttribute('hidden', '');
      _rightConsoleElement.setAttribute('hidden', '');
      webTabBar.setAttr('hidden');
      webLayoutTabController.selectTab('dart');
      checkmarkIcons[2].classes.remove('hide');
    }
  }

  // GistContainer interface
  @override
  MutableGist get mutableGist => editableGist;

  @override
  void overrideNextRoute(Gist gist) {
    _overrideNextRouteGist = gist;
  }

  Future _showCreateGistDialog() async {
    var result = await dialog.showOkCancel(
        'Create New Pad', 'Discard changes to the current pad?');
    if (result == DialogResult.ok) {
      var layout = await newPadDialog.show();
      await createNewGist();
      _changeLayout(layout);
    }
  }

  Future _showResetDialog() async {
    var result = await dialog.showOkCancel(
        'Reset Pad', 'Discard changes to the current pad?');
    if (result == DialogResult.ok) {
      _resetGists();
    }
  }

  void _showSharingPage() {
    window.open('https://github.com/dart-lang/dart-pad/wiki/Sharing-Guide',
        'DartPad Sharing Guide');
  }

  void _showGitHubPage() {
    window.open('https://github.com/dart-lang/dart-pad', 'DartPad on GitHub');
  }

  @override
  Future createNewGist() {
    _gistStorage.clearStoredGist();

    if (ga != null) ga.sendEvent('main', 'new');

    _showSnackbar('New pad created');
    router.go('gist', {'gist': ''}, forceReload: true);

    return Future.value();
  }

  void _resetGists() {
    _gistStorage.clearStoredGist();
    editableGist.reset();
    // Delay to give time for the model change event to propagate through
    // to the editor component (which is where `_performAnalysis()` pulls
    // the Dart source from).
    Timer.run(_performAnalysis);
    _clearOutput();
  }

  void _displayIssues(List<AnalysisIssue> issues) {
    analysisResultsController.display(issues);
  }

  void _jumpTo(int line, int charStart, int charLength, {bool focus = false}) {
    final doc = editor.document;

    doc.select(
        doc.posFromIndex(charStart), doc.posFromIndex(charStart + charLength));

    if (focus) editor.focus();
  }

  void _jumpToLine(int line) {
    final doc = editor.document;
    doc.select(Position(line, 0), Position(line, 0));

    editor.focus();
  }
}

/// Adds a ripple effect to material design buttons
class MDCButton extends DButton {
  final MDCRipple ripple;
  MDCButton(ButtonElement element, {bool isIcon = false})
      : ripple = MDCRipple(element)..unbounded = isIcon,
        super(element);
}

enum Layout {
  flutter,
  dart,
  web,
}

// HTML for keyboard shortcuts dialog
String keyMapToHtml(Map<Action, Set<String>> keyMap) {
  DListElement dl = DListElement();
  keyMap.forEach((Action action, Set<String> keys) {
    if (!action.hidden) {
      String string = '';
      for (final key in keys) {
        if (makeKeyPresentable(key) != null) {
          string += '<span>${makeKeyPresentable(key)}</span>';
        }
      }
      dl.innerHtml += '<dt>$action</dt><dd>$string</dd>';
    }
  });

  var keysDialogDiv = DivElement()
    ..children.add(dl)
    ..classes.add('keys-dialog');
  var div = DivElement()..children.add(keysDialogDiv);

  return div.innerHtml;
}

enum TabState {
  closed,
  docs,
  console,
}

/// Manages the bottom-left panel and tabs
class TabExpandController {
  final MDCButton consoleButton;
  final MDCButton docsButton;
  final MDCButton closeButton;
  final DElement console;
  final DElement docs;
  final Counter unreadCounter;

  /// The element to give the top half of the split when this panel
  /// opens
  final Element topSplit;

  /// The element to give the bottom half of the split
  final Element bottomSplit;

  final List<StreamSubscription> _subscriptions = [];

  TabState _state;
  Splitter _splitter;
  bool _splitterConfigured = false;

  TabState get state => _state;

  TabExpandController({
    @required this.consoleButton,
    @required this.docsButton,
    @required this.closeButton,
    @required Element consoleElement,
    @required Element docsElement,
    @required this.topSplit,
    @required this.bottomSplit,
    @required this.unreadCounter,
  })  : console = DElement(consoleElement),
        docs = DElement(docsElement) {
    _state = TabState.closed;
    console.setAttr('hidden');
    docs.setAttr('hidden');

    _subscriptions.add(consoleButton.onClick.listen((_) {
      toggleConsole();
    }));

    _subscriptions.add(docsButton.onClick.listen((_) {
      toggleDocs();
    }));

    _subscriptions.add(closeButton.onClick.listen((_) {
      _hidePanel();
    }));
  }

  void toggleConsole() {
    if (_state == TabState.closed) {
      _showConsole();
    } else if (_state == TabState.docs) {
      _showConsole();
      docs.setAttr('hidden');
      docsButton.toggleClass('active', false);
    } else if (_state == TabState.console) {
      _hidePanel();
    }
  }

  void toggleDocs() {
    if (_state == TabState.closed) {
      _showDocs();
    } else if (_state == TabState.console) {
      _showDocs();
      console.setAttr('hidden');
      consoleButton.toggleClass('active', false);
    } else if (_state == TabState.docs) {
      _hidePanel();
    }
  }

  void _showConsole() {
    unreadCounter.clear();
    _state = TabState.console;
    console.clearAttr('hidden');
    bottomSplit.classes.remove('border-top');
    consoleButton.toggleClass('active', true);
    _initSplitter();
    closeButton.toggleAttr('hidden', false);
  }

  void _hidePanel() {
    _destroySplitter();
    _state = TabState.closed;
    console.setAttr('hidden');
    docs.setAttr('hidden');
    bottomSplit.classes.add('border-top');
    consoleButton.toggleClass('active', false);
    docsButton.toggleClass('active', false);
    closeButton.toggleAttr('hidden', true);
  }

  void _showDocs() {
    _state = TabState.docs;
    docs.clearAttr('hidden');
    bottomSplit.classes.remove('border-top');
    docsButton.toggleClass('active', true);
    _initSplitter();
    closeButton.toggleAttr('hidden', false);
  }

  void _initSplitter() {
    if (_splitterConfigured) {
      return;
    }

    _splitter = flexSplit(
      [topSplit, bottomSplit],
      horizontal: false,
      gutterSize: 6,
      sizes: [70, 30],
      minSize: [100, 100],
    );
    _splitterConfigured = true;
  }

  void _destroySplitter() {
    if (!_splitterConfigured) {
      return;
    }

    _splitter?.destroy();
    _splitterConfigured = false;
  }

  void dispose() {
    bottomSplit.classes.add('border-top');
    _destroySplitter();

    // Reset selected tab
    docsButton.toggleClass('active', false);
    consoleButton.toggleClass('active', false);

    // Clear listeners
    _subscriptions.forEach((s) => s.cancel());
    _subscriptions.clear();
  }
}

class NewPadDialog {
  final MDCDialog _mdcDialog;
  final MDCRipple _dartButton;
  final MDCRipple _flutterButton;
  final MDCButton _createButton;
  final MDCButton _cancelButton;
  final MDCSwitch _htmlSwitch;
  final DElement _htmlSwitchContainer;

  NewPadDialog()
      : assert(querySelector('#new-pad-dialog') != null),
        assert(querySelector('#new-pad-select-dart') != null),
        assert(querySelector('#new-pad-select-flutter') != null),
        assert(querySelector('#new-pad-cancel-button') != null),
        assert(querySelector('#new-pad-create-button') != null),
        assert(querySelector('#new-pad-html-switch-container') != null),
        assert(querySelector('#new-pad-html-switch-container .mdc-switch') !=
            null),
        _mdcDialog = MDCDialog(querySelector('#new-pad-dialog')),
        _dartButton = MDCRipple(querySelector('#new-pad-select-dart')),
        _flutterButton = MDCRipple(querySelector('#new-pad-select-flutter')),
        _cancelButton = MDCButton(querySelector('#new-pad-cancel-button')),
        _createButton = MDCButton(querySelector('#new-pad-create-button')),
        _htmlSwitchContainer =
            DElement(querySelector('#new-pad-html-switch-container')),
        _htmlSwitch = MDCSwitch(
            querySelector('#new-pad-html-switch-container .mdc-switch'));

  Layout get selectedLayout {
    if (_dartButton.root.classes.contains('selected')) {
      return _htmlSwitch.checked ? Layout.web : Layout.dart;
    }

    if (_flutterButton.root.classes.contains('selected')) {
      return Layout.flutter;
    }

    return null;
  }

  Future<Layout> show() {
    _createButton.toggleAttr('disabled', true);

    var completer = Completer<Layout>();
    var dartSub = _dartButton.root.onClick.listen((_) {
      _flutterButton.root.classes.remove('selected');
      _dartButton.root.classes.add('selected');
      _createButton.toggleAttr('disabled', false);
      _htmlSwitchContainer.toggleAttr('hidden', false);
      _htmlSwitch.disabled = false;
    });

    var flutterSub = _flutterButton.root.onClick.listen((_) {
      _dartButton.root.classes.remove('selected');
      _flutterButton.root.classes.add('selected');
      _createButton.toggleAttr('disabled', false);
      _htmlSwitchContainer.toggleAttr('hidden', true);
    });

    var cancelSub = _cancelButton.onClick.listen((_) {
      completer.complete(null);
    });

    var createSub = _createButton.onClick.listen((_) {
      completer.complete(selectedLayout);
    });

    _mdcDialog.open();

    return completer.future.then((v) {
      _flutterButton.root.classes.remove('selected');
      _dartButton.root.classes.remove('selected');
      dartSub.cancel();
      flutterSub.cancel();
      cancelSub.cancel();
      createSub.cancel();
      _mdcDialog.close();
      return v;
    });
  }
}
