// tui.js — Unicode-safe terminal layout helpers.
//
// JavaScript string length counts UTF-16 code units, not terminal columns. CJK
// characters and emoji commonly occupy two columns, while combining marks and
// ANSI escape sequences occupy none. All box geometry must therefore use
// displayWidth() rather than String#length or String#padEnd().

import pc from 'picocolors';

const ANSI_PATTERN = /[\u001B\u009B][[\]()#;?]*(?:(?:(?:;[-a-zA-Z\d/#&.:=?%@~_]+)*|[a-zA-Z\d]+(?:;[-a-zA-Z\d/#&.:=?%@~_]*)*)?\u0007|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g;
const MARK = /^\p{Mark}+$/u;
const EMOJI_PRESENTATION = /\p{Emoji_Presentation}|\p{Regional_Indicator}/u;
const GRAPHEME_SEGMENTER = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
const WORD_SEGMENTER = new Intl.Segmenter(undefined, { granularity: 'word' });
const TAB_SIZE = 4;

function stripAnsi(value) {
  return String(value).replace(ANSI_PATTERN, '');
}

function isZeroWidth(codePoint, character) {
  return (
    codePoint === 0x200d || // zero-width joiner
    codePoint === 0x200c || // zero-width non-joiner
    codePoint === 0xfe0e ||
    codePoint === 0xfe0f || // variation selectors
    (codePoint >= 0x1f3fb && codePoint <= 0x1f3ff) || // emoji modifiers
    (codePoint >= 0xe0020 && codePoint <= 0xe007f) || // emoji tags
    MARK.test(character)
  );
}

// Adapted from the Unicode ranges used by is-fullwidth-code-point. Ambiguous
// width characters intentionally remain one column, matching common terminals.
function isFullWidthCodePoint(codePoint) {
  return codePoint >= 0x1100 && (
    codePoint <= 0x115f ||
    codePoint === 0x2329 ||
    codePoint === 0x232a ||
    (codePoint >= 0x2e80 && codePoint <= 0x303e) ||
    (codePoint >= 0x3040 && codePoint <= 0xa4cf) ||
    (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0xfe10 && codePoint <= 0xfe19) ||
    (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
    (codePoint >= 0xff00 && codePoint <= 0xff60) ||
    (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
    (codePoint >= 0x1b000 && codePoint <= 0x1b2ff) ||
    (codePoint >= 0x1f200 && codePoint <= 0x1f251) ||
    (codePoint >= 0x20000 && codePoint <= 0x3fffd)
  );
}

function graphemeWidth(grapheme, currentColumn = 0) {
  if (grapheme === '\t') return TAB_SIZE - (currentColumn % TAB_SIZE);
  if (EMOJI_PRESENTATION.test(grapheme) || grapheme.includes('\ufe0f') || grapheme.includes('\u200d')) return 2;

  let width = 0;
  for (const character of grapheme) {
    const codePoint = character.codePointAt(0);
    if (
      codePoint === 0 ||
      codePoint < 0x20 ||
      (codePoint >= 0x7f && codePoint < 0xa0) ||
      isZeroWidth(codePoint, character)
    ) continue;
    width += isFullWidthCodePoint(codePoint) ? 2 : 1;
  }
  return width;
}

function graphemes(value) {
  return [...GRAPHEME_SEGMENTER.segment(stripAnsi(value))].map(({ segment }) => segment);
}

export function displayWidth(value) {
  let maximum = 0;
  for (const line of stripAnsi(value).split('\n')) {
    let width = 0;
    for (const grapheme of graphemes(line)) {
      width += graphemeWidth(grapheme, width);
    }
    maximum = Math.max(maximum, width);
  }
  return maximum;
}

export function padDisplay(value, targetWidth) {
  const text = String(value);
  return text + ' '.repeat(Math.max(0, targetWidth - displayWidth(text)));
}

function takeDisplay(value, maximumWidth) {
  let result = '';
  let width = 0;
  for (const grapheme of graphemes(value)) {
    const nextWidth = graphemeWidth(grapheme, width);
    if (width + nextWidth > maximumWidth) break;
    result += grapheme;
    width += nextWidth;
  }
  return result;
}

export function wrapDisplay(value, maximumWidth, options = {}) {
  if (!Number.isFinite(maximumWidth) || maximumWidth < 1) {
    throw new RangeError('maximumWidth must be a positive number');
  }

  const continuationIndent = stripAnsi(options.continuationIndent || '');
  const indent = takeDisplay(continuationIndent, Math.max(0, maximumWidth - 2));
  const indentWidth = displayWidth(indent);
  const wrapped = [];

  for (const originalLine of stripAnsi(value).split('\n')) {
    const sourceLine = continuationIndent && originalLine.startsWith(continuationIndent)
      ? indent + originalLine.slice(continuationIndent.length)
      : originalLine;
    let line = '';
    let width = 0;

    const pushLine = () => {
      wrapped.push(line.trimEnd());
      line = indent;
      width = indentWidth;
    };

    const appendHardWrapped = (token) => {
      for (const grapheme of graphemes(token)) {
        const nextWidth = graphemeWidth(grapheme, width);
        if (width > indentWidth && width + nextWidth > maximumWidth) pushLine();
        line += grapheme;
        width += graphemeWidth(grapheme, width);
      }
    };

    for (const { segment: token } of WORD_SEGMENTER.segment(sourceLine)) {
      const tokenWidth = displayWidth(token);
      if (width + tokenWidth <= maximumWidth) {
        line += token;
        width += tokenWidth;
        continue;
      }

      if (line.trim().length > 0) pushLine();
      if (/^\s+$/u.test(token)) continue;

      if (width + tokenWidth <= maximumWidth) {
        line += token;
        width += tokenWidth;
      } else {
        appendHardWrapped(token);
      }
    }
    wrapped.push(line.trimEnd());
  }
  return wrapped;
}

function truncateDisplay(value, maximumWidth) {
  if (displayWidth(value) <= maximumWidth) return String(value);
  if (maximumWidth <= 1) return '…'.slice(0, maximumWidth);

  let result = '';
  let width = 0;
  for (const grapheme of graphemes(value)) {
    const nextWidth = graphemeWidth(grapheme, width);
    if (width + nextWidth > maximumWidth - 1) break;
    result += grapheme;
    width += nextWidth;
  }
  return `${result}…`;
}

export function renderNote(message = '', title = '', options = {}) {
  const requestedColumns = Number(options.columns);
  const columns = Number.isFinite(requestedColumns) && requestedColumns > 0
    ? Math.max(10, Math.floor(requestedColumns))
    : 80;
  const color = options.color !== false;
  const style = color
    ? { gray: pc.gray, green: pc.green, dim: pc.dim, reset: pc.reset }
    : { gray: String, green: String, dim: String, reset: String };

  const rawLines = String(message).split('\n');
  const naturalWidth = Math.max(
    displayWidth(title),
    ...rawLines.map(displayWidth),
  );
  const boxWidth = Math.min(columns, Math.max(10, naturalWidth + 6));
  const contentWidth = boxWidth - 4;
  const visibleTitle = truncateDisplay(title, Math.max(1, contentWidth - 2));
  const titleWidth = displayWidth(visibleTitle);
  const horizontal = '─'.repeat(Math.max(contentWidth - titleWidth - 1, 1));
  const bodyLines = rawLines.flatMap((line) => {
    const continuationIndent = line.match(/^ */u)?.[0] || '';
    return wrapDisplay(line, contentWidth, { continuationIndent });
  });
  const framedLines = ['', ...bodyLines, ''].map((line) =>
    `${style.gray('│')}  ${style.dim(padDisplay(line, contentWidth))}${style.gray('│')}`,
  );

  return [
    style.gray('│'),
    `${style.green('◇')}  ${style.reset(visibleTitle)} ${style.gray(`${horizontal}╮`)}`,
    ...framedLines,
    style.gray(`├${'─'.repeat(contentWidth + 2)}╯`),
    '',
  ].join('\n');
}

export function note(message = '', title = '', options = {}) {
  const stream = options.stream || process.stdout;
  stream.write(renderNote(message, title, {
    columns: options.columns ?? stream.columns,
    color: options.color,
  }));
}
