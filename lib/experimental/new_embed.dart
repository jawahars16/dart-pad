// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html' hide Document, Console;
import 'dart:math' as math;

import 'package:dart_pad/experimental/material_tab_controller.dart';
import 'package:dart_pad/src/ga.dart';
import 'package:split/split.dart';
import 'package:mdc_web/mdc_web.dart';

import '../completion.dart';
import '../core/dependencies.dart';
import '../core/modules.dart';
import '../dart_pad.dart';
import '../editing/editor.dart';
import '../editing/editor_codemirror.dart';
import '../elements/elements.dart';
import '../modules/dart_pad_module.dart';
import '../modules/dartservices_module.dart';
import '../services/common.dart';
import '../services/dartservices.dart';
import '../services/execution_iframe.dart';
import '../sharing/gists.dart';
import '../src/util.dart';
import 'analysis_results_controller.dart';
import 'console.dart';
import 'counter.dart';
import 'dialog.dart';

const int defaultSplitterWidth = 6;

NewEmbed get newEmbed => _newEmbed;

NewEmbed _newEmbed;

var codeMirrorOptions = {
  'continueComments': {'continueLineComment': false},
  'autofocus': false,
  'autoCloseBrackets': true,
  'matchBrackets': true,
  'tabSize': 2,
  'lineWrapping': true,
  'indentUnit': 2,
  'cursorHeight': 0.85,
  'viewportMargin': 100,
  'extraKeys': {
    'Cmd-/': 'toggleComment',
    'Ctrl-/': 'toggleComment',
    'Tab': 'insertSoftTab'
  },
  'hintOptions': {'completeSingle': false},
  'theme': 'zenburn',
  'scrollbarStyle': 'simple',
};

void init(NewEmbedOptions options) {
  _newEmbed = NewEmbed(options);
}

enum NewEmbedMode { dart, flutter, html, inline }

class NewEmbedOptions {
  final NewEmbedMode mode;

  NewEmbedOptions(this.mode);
}

/// An embeddable DartPad UI that provides the ability to test the user's code
/// snippet against a desired result.
class NewEmbed {
  final NewEmbedOptions options;

  var _executionButtonCount = 0;
  DisableableButton executeButton;
  DisableableButton reloadGistButton;
  DisableableButton formatButton;
  DisableableButton showHintButton;
  DisableableButton copyCodeButton;
  DisableableButton menuButton;

  DElement navBarElement;
  NewEmbedTabController tabController;
  TabView editorTabView;
  TabView testTabView;
  TabView solutionTabView;
  TabView htmlTabView;
  TabView cssTabView;
  DElement solutionTab;
  MDCMenu menu;

  DElement morePopover;
  DElement showTestCodeCheckmark;
  bool _showTestCode = false;

  Counter unreadConsoleCounter;

  FlashBox testResultBox;
  FlashBox hintBox;

  ExecutionService executionSvc;

  CodeMirrorFactory editorFactory = codeMirrorFactory;

  Editor userCodeEditor;
  Editor testEditor;
  Editor solutionEditor;
  Editor htmlEditor;
  Editor cssEditor;

  NewEmbedContext context;

  Splitter splitter;
  AnalysisResultsController analysisResultsController;

  Console consoleExpandController;
  DElement webOutputLabel;

  MDCLinearProgress linearProgress;
  Dialog dialog;
  Map<String, String> lastInjectedSourceCode = <String, String>{};

  final DelayedTimer _debounceTimer = DelayedTimer(
    minDelay: Duration(milliseconds: 1000),
    maxDelay: Duration(milliseconds: 5000),
  );

  bool _editorIsBusy = true;

  bool get editorIsBusy => _editorIsBusy;

  /// Toggles the state of several UI components based on whether the editor is
  /// too busy to handle code changes, execute/reset requests, etc.
  set editorIsBusy(bool value) {
    _editorIsBusy = value;
    if (value) {
      linearProgress.root.classes.remove('hide');
    } else {
      linearProgress.root.classes.add('hide');
    }
    userCodeEditor.readOnly = value;
    executeButton.disabled = value;
    formatButton.disabled = value;
    reloadGistButton.disabled = value;
    showHintButton?.disabled = value;
    copyCodeButton?.disabled = value;
  }

  NewEmbed(this.options) {
    _initHostListener();
    dialog = Dialog();
    tabController =
        NewEmbedTabController(MDCTabBar(querySelector('.mdc-tab-bar')), dialog);

    var tabNames = ['editor', 'solution', 'test'];
    if (options.mode == NewEmbedMode.html) {
      tabNames = ['editor', 'html', 'css', 'solution', 'test'];
    }

    for (var name in tabNames) {
      tabController.registerTab(
        TabElement(querySelector('#$name-tab'), name: name, onSelect: () {
          editorTabView?.setSelected(name == 'editor');
          testTabView?.setSelected(name == 'test');
          solutionTabView?.setSelected(name == 'solution');
          htmlTabView?.setSelected(name == 'html');
          cssTabView?.setSelected(name == 'css');

          if (name == 'editor') {
            userCodeEditor.resize();
            userCodeEditor.focus();
          } else if (name == 'test') {
            testEditor.resize();
            testEditor.focus();
          } else if (name == 'solution') {
            solutionEditor.resize();
            solutionEditor.focus();
          } else if (name == 'html') {
            htmlEditor.resize();
            htmlEditor.focus();
          } else if (name == 'css') {
            cssEditor.resize();
            cssEditor.focus();
          }
        }),
      );
    }

    solutionTab = DElement(querySelector('#solution-tab'));

    navBarElement = DElement(querySelector('#navbar'));

    unreadConsoleCounter = Counter(querySelector('#unread-console-counter'));

    executeButton =
        DisableableButton(querySelector('#execute'), _handleExecute);

    reloadGistButton = DisableableButton(querySelector('#reload-gist'), () {
      if (gistId.isNotEmpty || sampleId.isNotEmpty || githubParamsPresent) {
        _loadAndShowGist();
      } else {
        _resetCode();
      }
    });

    copyCodeButton =
        DisableableButton(querySelector('#copy-code'), _handleCopyCode);

    showHintButton = DisableableButton(querySelector('#show-hint'), () {
      var hintElement = DivElement()..text = context.hint;
      var showSolutionButton = AnchorElement()
        ..style.cursor = 'pointer'
        ..text = 'Show solution';
      showSolutionButton.onClick.listen((_) {
        tabController.selectTab('solution', force: true);
      });
      hintBox.showElements([hintElement, showSolutionButton]);
      ga?.sendEvent('view', 'hint');
    })
      ..hidden = true;

    tabController.setTabVisibility('test', false);
    showTestCodeCheckmark = DElement(querySelector('#show-test-checkmark'));

    morePopover = DElement(querySelector('#more-popover'));
    menuButton = DisableableButton(querySelector('#menu-button'), () {
      menu.open = !menu.open;
    });
    menu = MDCMenu(querySelector('#main-menu'))
      ..setAnchorCorner(AnchorCorner.bottomLeft)
      ..setAnchorElement(menuButton._element.element);
    menu.listen('MDCMenu:selected', (e) {
      if ((e as CustomEvent).detail['index'] == 0) {
        _showTestCode = !_showTestCode;
        showTestCodeCheckmark.toggleClass('hide', !_showTestCode);
        tabController.setTabVisibility('test', _showTestCode);
      }
    });

    formatButton = DisableableButton(
      querySelector('#format-code'),
      _performFormat,
    );

    testResultBox = FlashBox(querySelector('#test-result-box'));
    hintBox = FlashBox(querySelector('#hint-box'));
    var editorTheme = isDarkMode ? 'darkpad' : 'dartpad';

    userCodeEditor = editorFactory.createFromElement(
        querySelector('#user-code-editor'),
        options: codeMirrorOptions)
      ..theme = editorTheme
      ..mode = 'dart'
      ..showLineNumbers = true;
    userCodeEditor.document.onChange.listen(_performAnalysis);
    userCodeEditor.autoCloseBrackets = false;

    testEditor = editorFactory.createFromElement(querySelector('#test-editor'),
        options: codeMirrorOptions)
      ..theme = editorTheme
      ..mode = 'dart'
      ..readOnly = true
      ..showLineNumbers = true;

    solutionEditor = editorFactory.createFromElement(
        querySelector('#solution-editor'),
        options: codeMirrorOptions)
      ..theme = editorTheme
      ..mode = 'dart'
      ..readOnly = true
      ..showLineNumbers = true;

    htmlEditor = editorFactory.createFromElement(querySelector('#html-editor'),
        options: codeMirrorOptions)
      ..theme = editorTheme
      // TODO(ryjohn): why doesn't editorFactory.modes have html?
      ..mode = 'xml'
      ..showLineNumbers = true;

    cssEditor = editorFactory.createFromElement(querySelector('#css-editor'),
        options: codeMirrorOptions)
      ..theme = editorTheme
      ..mode = 'css'
      ..showLineNumbers = true;

    var editorTabViewElement = querySelector('#user-code-view');
    if (editorTabViewElement != null) {
      editorTabView = TabView(DElement(editorTabViewElement));
    }

    var testTabViewElement = querySelector('#test-view');
    if (testTabViewElement != null) {
      testTabView = TabView(DElement(testTabViewElement));
    }

    var solutionTabViewElement = querySelector('#solution-view');
    if (solutionTabViewElement != null) {
      solutionTabView = TabView(DElement(solutionTabViewElement));
    }

    var htmlTabViewElement = querySelector('#html-view');
    if (htmlTabViewElement != null) {
      htmlTabView = TabView(DElement(htmlTabViewElement));
    }

    var cssTabViewElement = querySelector('#css-view');
    if (cssTabViewElement != null) {
      cssTabView = TabView(DElement(querySelector('#css-view')));
    }

    executionSvc = ExecutionServiceIFrame(querySelector('#frame'))
      ..frameSrc =
          isDarkMode ? '../scripts/frame_dark.html' : '../scripts/frame.html';

    executionSvc.onStderr.listen((err) {
      consoleExpandController.showOutput(err, error: true);
    });

    executionSvc.onStdout.listen((msg) {
      consoleExpandController.showOutput(msg);
    });

    executionSvc.testResults.listen((result) {
      if (result.messages.isEmpty) {
        result.messages
            .add(result.success ? 'All tests passed!' : 'Test failed.');
      }
      testResultBox.showStrings(
        result.messages,
        result.success ? FlashBoxStyle.success : FlashBoxStyle.warn,
      );
      ga?.sendEvent(
          'execution', (result.success) ? 'test-success' : 'test-failure');
    });

    analysisResultsController = AnalysisResultsController(
        DElement(querySelector('#issues')),
        DElement(querySelector('#issues-message')),
        DElement(querySelector('#issues-toggle')))
      ..onIssueClick.listen((issue) {
        _jumpTo(issue.line, issue.charStart, issue.charLength, focus: true);
      });

    if (options.mode == NewEmbedMode.flutter ||
        options.mode == NewEmbedMode.html) {
      consoleExpandController = ConsoleExpandController(
          expandButton: querySelector('#console-output-header'),
          footer: querySelector('#console-output-footer'),
          expandIcon: querySelector('#console-expand-icon'),
          unreadCounter: unreadConsoleCounter,
          consoleElement: querySelector('#console-output-container'),
          onSizeChanged: () {
            userCodeEditor.resize();
            testEditor.resize();
            solutionEditor.resize();
            htmlEditor.resize();
            cssEditor.resize();
          });
    } else {
      consoleExpandController =
          Console(DElement(querySelector('#console-output-container')));
    }

    var webOutputLabelElement = querySelector('#web-output-label');
    if (webOutputLabelElement != null) {
      webOutputLabel = DElement(webOutputLabelElement);
    }

    linearProgress = MDCLinearProgress(querySelector('#progress-bar'));
    linearProgress.determinate = false;

    _initializeMaterialRipples();
    _initModules()
        .then((_) => _initNewEmbed())
        .then((_) => _emitReady())
        .then((_) {
      if (options.mode == NewEmbedMode.flutter) {
        _notifyIfWebKit();
      }
    });
  }

  /// Initializes a listener for messages from the parent window. Allows this
  /// embedded iframe to display and run arbitrary Dart code.
  void _initHostListener() {
    window.addEventListener('message', (dynamic event) {
      var data = event.data;
      if (data is! Map) {
        // Ignore unexpected messages
        return;
      }

      var type = data['type'];

      if (type == 'sourceCode') {
        lastInjectedSourceCode = Map<String, String>.from(data['sourceCode']);
        _resetCode();

        if(autoRunEnabled) {
          _handleExecute();
        }
      }
    });
  }

  /// Sends a ready message to the parent page
  void _emitReady() {
    window.parent.postMessage({'sender': 'frame', 'type': 'ready'}, '*');
  }

  String _getQueryParam(String key) {
    final url = Uri.parse(window.location.toString());

    if (url.hasQuery && url.queryParameters[key] != null) {
      return url.queryParameters[key];
    }

    return '';
  }

  // Option for the GitHub gist ID that should be loaded into the editors.
  String get gistId {
    final id = _getQueryParam('id');
    return isLegalGistId(id) ? id : '';
  }

  // Option for Light / Dark theme (defaults to light)
  bool get isDarkMode {
    final url = Uri.parse(window.location.toString());
    return url.queryParameters['theme'] == 'dark';
  }

  // Option to run the snippet immediately (defaults to  false)
  bool get autoRunEnabled {
    final url = Uri.parse(window.location.toString());
    return url.queryParameters['run'] == 'true';
  }

  // ID of an API Doc sample that should be loaded into the editors.
  String get sampleId => _getQueryParam('sample_id');

  // GitHub params for loading an exercise from a repo. The first three are
  // required to load something, while the fourth, gh_ref, is an optional branch
  // name or commit SHA.
  String get githubOwner => _getQueryParam('gh_owner');

  String get githubRepo => _getQueryParam('gh_repo');

  String get githubPath => _getQueryParam('gh_path');

  String get githubRef => _getQueryParam('gh_ref');

  bool get githubParamsPresent =>
      githubOwner.isNotEmpty && githubRepo.isNotEmpty && githubPath.isNotEmpty;

  Future<void> _initModules() async {
    ModuleManager modules = ModuleManager();

    modules.register(DartPadModule());
    modules.register(DartServicesModule());

    await modules.start();
  }

  void _notifyIfWebKit() {
    // See https://bugs.webkit.org/show_bug.cgi?id=199866.
    if (window.navigator.vendor.contains('Apple') &&
        !window.navigator.userAgent.contains('CriOS') &&
        !window.navigator.userAgent.contains('FxiOS')) {
      dialog.showOk('Possible delay', '''
<p>
It looks like you're using a WebKit-based browser (such as Safari). There's
currently an issue with the way DartPad and WebKit's JavaScript parser interact
that could cause up to a thirty second delay the first time you execute Flutter
code in DartPad. This is not an issue with Dart or Flutter itself, and we're
working with the WebKit team to resolve it.
</p>
<p>
In the meantime, it's possible to avoid the delay by using one of the other
major browsers, such as Firefox, Edge (dev channel), or Chrome.
</p>
''');
    }
  }

  void _initNewEmbed() {
    deps[GistLoader] = GistLoader.defaultFilters();
    deps[Analytics] = Analytics();

    context = NewEmbedContext(
        userCodeEditor, testEditor, solutionEditor, htmlEditor, cssEditor);

    editorFactory.registerCompleter(
        'dart', DartCompleter(dartServices, userCodeEditor.document));

    keys.bind(['ctrl-space', 'macctrl-space'], () {
      if (userCodeEditor.hasFocus) {
        userCodeEditor.showCompletions();
      }
    }, 'Completion');

    keys.bind(['alt-enter'], () {
      userCodeEditor.showCompletions(onlyShowFixes: true);
    }, 'Quick fix');

    keys.bind(['ctrl-enter', 'macctrl-enter'], _handleExecute, 'Run');

    document.onKeyUp.listen(_handleAutoCompletion);

    var horizontal = true;
    var webOutput = querySelector('#web-output');
    List<Element> splitterElements;
    if (options.mode == NewEmbedMode.flutter ||
        options.mode == NewEmbedMode.html) {
      var editorAndConsoleContainer =
          querySelector('#editor-and-console-container');
      splitterElements = [editorAndConsoleContainer, webOutput];
    } else if (options.mode == NewEmbedMode.inline) {
      var editorContainer = querySelector('#editor-container');
      var consoleView = querySelector('#console-view');
      consoleView.removeAttribute('hidden');
      splitterElements = [editorContainer, consoleView];
      horizontal = false;
    } else {
      var editorContainer = querySelector('#editor-container');
      var consoleView = querySelector('#console-view');
      consoleView.removeAttribute('hidden');
      splitterElements = [editorContainer, consoleView];
    }

    splitter = flexSplit(
      splitterElements,
      horizontal: horizontal,
      gutterSize: defaultSplitterWidth,
      // set initial sizes (in percentages)
      sizes: [initialSplitPercent, (100 - initialSplitPercent)],
      // set the minimum sizes (in pixels)
      minSize: [100, 100],
    );

    if (gistId.isNotEmpty || sampleId.isNotEmpty || githubParamsPresent) {
      _loadAndShowGist(analyze: false);
    }

    // set enabled/disabled state of various buttons
    editorIsBusy = false;
  }

  Future<void> _loadAndShowGist({bool analyze = true}) async {
    if (gistId.isEmpty && sampleId.isEmpty && !githubParamsPresent) {
      print('Cannot load gist: neither id, sample_id, nor GitHub repo info is '
          'present.');
      return;
    }

    editorIsBusy = true;

    final GistLoader loader = deps[GistLoader];

    try {
      Gist gist;

      if (gistId.isNotEmpty) {
        gist = await loader.loadGist(gistId);
      } else if (sampleId.isNotEmpty) {
        gist = await loader.loadGistFromAPIDocs(sampleId);
      } else {
        gist = await loader.loadGistFromRepo(
          owner: githubOwner,
          repo: githubRepo,
          path: githubPath,
          ref: githubRef,
        );
      }

      setContextSources(<String, String>{
        'main.dart': gist.getFile('main.dart')?.content ?? '',
        'index.html': gist.getFile('index.html')?.content ?? '',
        'styles.css': gist.getFile('styles.css')?.content ?? '',
        'solution.dart': gist.getFile('solution.dart')?.content ?? '',
        'test.dart': gist.getFile('test.dart')?.content ?? '',
        'hint.txt': gist.getFile('hint.txt')?.content ?? '',
      });

      if (analyze) {
        _performAnalysis();
      }

      if(autoRunEnabled) {
        _handleExecute();
      }
    } on GistLoaderException catch (ex) {
      // No gist was loaded, so clear the editors.
      setContextSources(<String, String>{});

      if (ex.failureType == GistLoaderFailureType.contentNotFound) {
        await dialog.showOk(
            'Error loading gist',
            'No gist was found for the gist ID, sample ID, or repository '
                'information provided.');
      } else if (ex.failureType == GistLoaderFailureType.rateLimitExceeded) {
        await dialog.showOk(
            'Error loading files',
            'GitHub\'s rate limit for '
                'API requests has been exceeded. This is typically caused by '
                'repeatedly loading a single page that has many DartPad embeds or '
                'when many users are accessing DartPad (and therefore GitHub\'s '
                'API server) from a single, shared IP address. Quotas are '
                'typically renewed within an hour, so the best course of action is '
                'to try back later.');
      } else if (ex.failureType ==
          GistLoaderFailureType.invalidExerciseMetadata) {
        if (ex.message != null) {
          print(ex.message);
        }
        await dialog.showOk(
            'Error loading files',
            'DartPad could not load the requested exercise. Either one of the '
                'required files wasn\'t available, or the exercise metadata was '
                'invalid.');
      } else {
        await dialog.showOk('Error loading files',
            'An error occurred while the requested files.');
      }
    }
  }

  void _resetCode() {
    setContextSources(lastInjectedSourceCode);
  }

  void _handleCopyCode() {
    var textElement = document.createElement('textarea') as TextAreaElement;
    textElement.value = _getActiveSourceCode();
    document.body.append(textElement);
    textElement.select();
    document.execCommand('copy');
    textElement.remove();
  }

  String _getActiveSourceCode() {
    String activeSource;
    String activeTabName = tabController.selectedTab.name;

    switch (activeTabName) {
      case 'editor':
        activeSource = context.dartSource;
        break;
      case 'css':
        activeSource = context.cssSource;
        break;
      case 'html':
        activeSource = context.htmlSource;
        break;
      case 'solution':
        activeSource = context.solution;
        break;
      case 'test':
        activeSource = context.testMethod;
        break;
      default:
        activeSource = context.dartSource;
        break;
    }

    return activeSource;
  }

  void setContextSources(Map<String, String> sources) {
    context.dartSource = sources['main.dart'] ?? '';
    context.solution = sources['solution.dart'] ?? '';
    context.testMethod = sources['test.dart'] ?? '';
    context.htmlSource = sources['index.html'] ?? '';
    context.cssSource = sources['styles.css'] ?? '';
    context.hint = sources['hint.txt'] ?? '';
    tabController.setTabVisibility(
        'test', context.testMethod.isNotEmpty && _showTestCode);
    menuButton.hidden = context.testMethod.isEmpty;
    showHintButton?.hidden = context.hint.isEmpty;
    solutionTab?.toggleAttr('hidden', context.solution.isEmpty);
    editorIsBusy = false;
  }

  void _handleExecute() {
    if (editorIsBusy) {
      return;
    }

    if (context.dartSource.isEmpty) {
      dialog.showOk(
          'No code to execute',
          'Try entering some Dart code into the "Dart" tab, then click this '
              'button again to run it.');
      return;
    }

    _executionButtonCount++;
    ga?.sendEvent('execution', 'initiated', label: '$_executionButtonCount');

    editorIsBusy = true;
    testResultBox.hide();
    hintBox.hide();
    consoleExpandController.clear();

    final fullCode = '${context.dartSource}\n${context.testMethod}\n'
        '${executionSvc.testResultDecoration}';

    var input = CompileRequest()..source = fullCode;
    if (options.mode == NewEmbedMode.flutter) {
      dartServices
          .compileDDC(input)
          .timeout(longServiceCallTimeout)
          .then((CompileDDCResponse response) {
        executionSvc.execute(
          '',
          '',
          response.result,
          modulesBaseUrl: response.modulesBaseUrl,
        );
        ga?.sendEvent('execution', 'ddc-compile-success');
      }).catchError((e, st) {
        consoleExpandController.showOutput('Error compiling to JavaScript:\n$e',
            error: true);
        print(st);
        ga?.sendEvent('execution', 'ddc-compile-failure');
      }).whenComplete(() {
        webOutputLabel.setAttr('hidden');
        editorIsBusy = false;
      });
    } else if (options.mode == NewEmbedMode.html) {
      dartServices
          .compile(input)
          .timeout(longServiceCallTimeout)
          .then((CompileResponse response) {
        ga?.sendEvent('execution', 'html-compile-success');
        return executionSvc.execute(
            context.htmlSource, context.cssSource, response.result);
      }).catchError((e, st) {
        consoleExpandController.showOutput('Error compiling to JavaScript:\n$e',
            error: true);
        print(st);
        ga?.sendEvent('execution', 'html-compile-failure');
      }).whenComplete(() {
        webOutputLabel.setAttr('hidden');
        editorIsBusy = false;
      });
    } else {
      dartServices
          .compile(input)
          .timeout(longServiceCallTimeout)
          .then((CompileResponse response) {
        executionSvc.execute('', '', response.result);
        ga?.sendEvent('execution', 'compile-success');
      }).catchError((e, st) {
        consoleExpandController.showOutput('Error compiling to JavaScript:\n$e',
            error: true);
        print(st);
        ga?.sendEvent('execution', 'compile-failure');
      }).whenComplete(() {
        editorIsBusy = false;
      });
    }
  }

  void _displayIssues(List<AnalysisIssue> issues) {
    testResultBox.hide();
    hintBox.hide();
    analysisResultsController.display(issues);
  }

  /// Perform static analysis of the source code.
  void _performAnalysis([_]) {
    _debounceTimer.invoke(() {
      final dartServices = deps[DartservicesApi] as DartservicesApi;
      final userSource = context.dartSource;
      // Create a synthesis of the user code and other code to analyze.
      final fullSource = '$userSource\n'
          '${context.testMethod}\n'
          '${executionSvc.testResultDecoration}\n';
      final sourceRequest = SourceRequest()..source = fullSource;
      final lines = Lines(sourceRequest.source);

      dartServices
          .analyze(sourceRequest)
          .timeout(serviceCallTimeout)
          .then((AnalysisResults result) {
        // Discard if the document has been mutated since we requested analysis.
        if (userSource != context.dartSource) return;

        _displayIssues(result.issues);

        Iterable<Annotation> issues = result.issues.map((AnalysisIssue issue) {
          final charStart = issue.charStart;
          final startLine = lines.getLineForOffset(charStart);
          final endLine = lines.getLineForOffset(charStart + issue.charLength);

          return Annotation(
            issue.kind,
            issue.message,
            issue.line,
            start: Position(
              startLine,
              charStart - lines.offsetForLine(startLine),
            ),
            end: Position(
              endLine,
              charStart + issue.charLength - lines.offsetForLine(startLine),
            ),
          );
        });

        userCodeEditor.document.setAnnotations(issues.toList());
      }).catchError((e) {
        if (e is! TimeoutException) {
          final String message = e is ApiRequestError ? e.message : '$e';

          _displayIssues([
            AnalysisIssue()
              ..kind = 'error'
              ..line = 1
              ..message = message
          ]);
          userCodeEditor.document.setAnnotations([]);
        }
      });
    });
  }

  void _performFormat() async {
    String originalSource = userCodeEditor.document.value;
    SourceRequest input = SourceRequest()..source = originalSource;

    try {
      formatButton.disabled = true;
      FormatResponse result =
          await dartServices.format(input).timeout(serviceCallTimeout);

      formatButton.disabled = false;

      // Check that the user hasn't edited the source since the format request.
      if (originalSource == userCodeEditor.document.value) {
        // And, check that the format request did modify the source code.
        if (originalSource != result.newString) {
          userCodeEditor.document.updateValue(result.newString);
          _performAnalysis();
        }
      }
    } catch (e) {
      formatButton.disabled = false;
      print(e);
    }
  }

  void _handleAutoCompletion(KeyboardEvent e) {
    if (userCodeEditor.hasFocus && e.keyCode == KeyCode.PERIOD) {
      userCodeEditor.showCompletions(autoInvoked: true);
    }
  }

  int get initialSplitPercent {
    const int defaultSplitPercentage = 70;

    final url = Uri.parse(window.location.toString());
    if (!url.queryParameters.containsKey('split')) {
      return defaultSplitPercentage;
    }

    var s =
        int.tryParse(url.queryParameters['split']) ?? defaultSplitPercentage;

    // keep the split within the range [5, 95]
    s = math.min(s, 95);
    s = math.max(s, 5);
    return s;
  }

  void _jumpTo(int line, int charStart, int charLength, {bool focus = false}) {
    Document doc = userCodeEditor.document;

    doc.select(
        doc.posFromIndex(charStart), doc.posFromIndex(charStart + charLength));

    if (focus) userCodeEditor.focus();
  }

  void _initializeMaterialRipples() {
    MDCRipple(executeButton._element.element);
    MDCRipple(reloadGistButton._element.element);
    MDCRipple(formatButton._element.element);
    MDCRipple(showHintButton._element.element);
  }
}

// material-components-web uses specific classes for its navigation styling,
// rather than an attribute. This class extends the tab controller code to also
// toggle that class.
class NewEmbedTabController extends MaterialTabController {
  final Dialog _dialog;
  bool _userHasSeenSolution = false;

  NewEmbedTabController(MDCTabBar tabBar, this._dialog) : super(tabBar);

  void registerTab(TabElement tab) {
    tabs.add(tab);

    try {
      tab.onClick
          .listen((_) => selectTab(tab.name, force: _userHasSeenSolution));
    } catch (e, st) {
      print('Error from registerTab: $e\n$st');
    }
  }

  /// This method will throw if the tabName is not the name of a current tab.
  @override
  Future selectTab(String tabName, {bool force = false}) async {
    // Show a confirmation dialog if the solution tab is tapped
    if (tabName == 'solution' && !force) {
      var result = await _dialog.showYesNo(
        'Show solution?',
        'If you just want a hint, click <span style="font-weight:bold">Cancel'
            '</span> and then <span style="font-weight:bold">Hint</span>.',
        yesText: "Show solution",
        noText: "Cancel",
      );
      // Go back to the editor tab
      if (result == DialogResult.no) {
        tabName = 'editor';
      }
    }

    if (tabName == 'solution') {
      ga?.sendEvent('view', 'solution');
      _userHasSeenSolution = true;
    }

    await super.selectTab(tabName);
  }
}

/// A container underneath the tab strip that can show or hide itself as needed.
class TabView {
  final DElement element;

  const TabView(this.element);

  void setSelected(bool selected) {
    if (selected) {
      element.clearAttr('hidden');
    } else {
      element.setAttr('hidden');
    }
  }
}

/// It's a real word, I swear.
class DisableableButton {
  DisableableButton(ButtonElement anchorElement, VoidCallback onClick)
      : assert(anchorElement != null),
        assert(onClick != null) {
    _element = DElement(anchorElement);
    _element.onClick.listen((e) {
      if (!_disabled) {
        onClick();
      }
    });
  }

  static const disabledClassName = 'disabled';

  DElement _element;

  bool _disabled = false;

  bool get disabled => _disabled;

  set disabled(bool value) {
    _disabled = value;
    _element.toggleClass(disabledClassName, value);
  }

  set hidden(bool value) {
    _element.toggleAttr('hidden', value);
  }
}

class Octicon {
  static const prefix = 'octicon-';

  Octicon(this.element);

  final DivElement element;

  String get iconName {
    return element.classes
        .firstWhere((s) => s.startsWith(prefix), orElse: () => '');
  }

  set iconName(String name) {
    element.classes.removeWhere((s) => s.startsWith(prefix));
    element.classes.add('$prefix$name');
  }

  static bool elementIsOcticon(Element el) =>
      el.classes.any((s) => s.startsWith(prefix));
}

enum FlashBoxStyle {
  warn,
  error,
  success,
}

class FlashBox {
  /// This constructor will throw if [div] does not have a child with the
  /// flash-close class and a child with the message-container class.
  FlashBox(DivElement div) {
    _element = DElement(div);
    _messageContainer = DElement(div.querySelector('.message-container'));

    final closeLink = DElement(div.querySelector('.flash-close'));
    closeLink.onClick.listen((event) {
      hide();
    });
  }

  static const classNamesForStyles = <FlashBoxStyle, String>{
    FlashBoxStyle.warn: 'flash-warn',
    FlashBoxStyle.error: 'flash-error',
    FlashBoxStyle.success: 'flash-success',
  };

  DElement _element;

  DElement _messageContainer;

  void showStrings(List<String> messages, [FlashBoxStyle style]) {
    showElements(messages.map((m) => DivElement()..text = m).toList(), style);
  }

  void showElements(List<Element> elements, [FlashBoxStyle style]) {
    _element.clearAttr('hidden');
    _element.element.classes
        .removeWhere((s) => classNamesForStyles.values.contains(s));

    if (style != null) {
      _element.toggleClass(classNamesForStyles[style], true);
    }

    _messageContainer.clearChildren();

    for (final element in elements) {
      _messageContainer.add(element);
    }
  }

  void hide() {
    _element.setAttr('hidden');
  }

  void show() {
    _element.clearAttr('hidden');
  }
}

class ConsoleExpandController extends Console {
  final DElement expandButton;
  final DElement footer;
  final DElement expandIcon;
  final Counter unreadCounter;
  final Function onSizeChanged;
  Splitter _splitter;
  bool _expanded;

  ConsoleExpandController({
    Element expandButton,
    Element footer,
    Element expandIcon,
    Element consoleElement,
    this.unreadCounter,
    this.onSizeChanged,
  })  : expandButton = DElement(expandButton),
        footer = DElement(footer),
        expandIcon = DElement(expandIcon),
        _expanded = false,
        super(DElement(consoleElement),
            errorClass: 'text-red', filter: filterCloudUrls) {
    super.element.setAttr('hidden');
    footer.removeAttribute('hidden');
    expandButton.onClick.listen((_) => _toggleExpanded());
  }

  void showOutput(String message, {bool error = false}) {
    super.showOutput(message, error: error);
    if (!_expanded && message != null) {
      unreadCounter.increment();
    }
  }

  void clear() {
    super.clear();
    unreadCounter.clear();
  }

  void _toggleExpanded() {
    _expanded = !_expanded;
    if (_expanded) {
      _initSplitter();
      _splitter.setSizes([60, 40]);
      element.toggleAttr('hidden', false);
      expandIcon.element.classes.remove('octicon-triangle-up');
      expandIcon.element.classes.add('octicon-triangle-down');
      footer.toggleClass('footer-top-border', false);
      unreadCounter.clear();
    } else {
      _splitter.setSizes([100, 0]);
      element.toggleAttr('hidden', true);
      expandIcon.element.classes.remove('octicon-triangle-down');
      expandIcon.element.classes.add('octicon-triangle-up');
      footer.toggleClass('footer-top-border', true);
      try {
        _splitter.destroy();
      } on NoSuchMethodError {
        // dart2js throws NoSuchMethodError (dartdevc is ok)
        // TODO(ryjohn): why does this happen?
      }
    }
    this.onSizeChanged();
  }

  void _initSplitter() {
    var splitterElements = [
      querySelector('#editor-container'),
      querySelector('#console-output-footer'),
    ];
    _splitter = flexSplit(
      splitterElements,
      horizontal: false,
      gutterSize: defaultSplitterWidth,
      sizes: [60, 40],
      minSize: [32, 32],
    );
  }
}

class NewEmbedContext {
  final Editor userCodeEditor;
  final Editor htmlEditor;
  final Editor cssEditor;
  final Editor testEditor;
  final Editor solutionEditor;

  Document _dartDoc;
  Document _htmlDoc;
  Document _cssDoc;

  String hint = '';

  String _solution = '';

  String get testMethod => testEditor.document.value;

  set testMethod(String value) {
    testEditor.document.value = value;
  }

  String get solution => _solution;

  set solution(String value) {
    _solution = value;
    solutionEditor.document.value = value;
  }

  final _dartDirtyController = StreamController.broadcast();

  final _dartReconcileController = StreamController.broadcast();

  NewEmbedContext(this.userCodeEditor, this.testEditor, this.solutionEditor,
      this.htmlEditor, this.cssEditor) {
    _dartDoc = userCodeEditor.document;
    _htmlDoc = htmlEditor?.document;
    _cssDoc = cssEditor?.document;
    _dartDoc.onChange.listen((_) => _dartDirtyController.add(null));
    _createReconciler(_dartDoc, _dartReconcileController, 1250);
  }

  Document get dartDocument => _dartDoc;

  String get dartSource => _dartDoc.value;

  String get htmlSource => _htmlDoc?.value;

  String get cssSource => _cssDoc?.value;

  set dartSource(String value) {
    userCodeEditor.document.value = value;
  }

  set htmlSource(String value) {
    htmlEditor.document.value = value;
  }

  set cssSource(String value) {
    cssEditor.document.value = value;
  }

  String get activeMode => userCodeEditor.mode;

  Stream get onDartDirty => _dartDirtyController.stream;

  Stream get onDartReconcile => _dartReconcileController.stream;

  void markDartClean() => _dartDoc.markClean();

  /// Restore the focus to the last focused editor.
  void focus() => userCodeEditor.focus();

  void _createReconciler(Document doc, StreamController controller, int delay) {
    Timer timer;
    doc.onChange.listen((_) {
      if (timer != null) timer.cancel();
      timer = Timer(Duration(milliseconds: delay), () {
        controller.add(null);
      });
    });
  }

  /// Return true if the current cursor position is in a whitespace char.
  bool cursorPositionIsWhitespace() {
    // TODO(DomesticMouse): implement with CodeMirror integration
    return false;
  }
}

final RegExp _flutterUrlExp =
    RegExp(r'(https:[a-zA-Z0-9_=%&\/\-\?\.]+flutter_web\.js)(:\d+:\d+)');
final RegExp _dartUrlExp =
    RegExp(r'(https:[a-zA-Z0-9_=%&\/\-\?\.]+dart_sdk\.js)(:\d+:\d+)');

String filterCloudUrls(String trace) {
  return trace
      ?.replaceAllMapped(
          _flutterUrlExp, (m) => '[Flutter SDK Source]${m.group(2)}')
      ?.replaceAllMapped(_dartUrlExp, (m) => '[Dart SDK Source]${m.group(2)}');
}
