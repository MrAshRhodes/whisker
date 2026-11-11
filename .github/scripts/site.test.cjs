'use strict';

// Checks the static product site in site/: the files and anchors other places link to, links that
// resolve, no third-party loads, a strict CSP with nothing inline, and the index page weight.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');

const site = path.join(__dirname, '..', '..', 'site');
const base = 'https://mrashrhodes.github.io/whisker/';
// GitHub Pages serves 404.html for any missing path, so it alone links from the project root.
const rootRelativePages = new Set(['404.html']);
const pages = fs.readdirSync(site).filter((name) => name.endsWith('.html')).sort();

const requiredFiles = ['index.html', 'guide.html', '404.html', '.nojekyll', 'site.css', 'site.js',
  'favicon.png', 'apple-touch-icon.png', 'og.png', 'robots.txt', 'sitemap.xml'];
// Linked from the app, the README, release notes and the issue template.
const guideAnchors = ['getting-started', 'permissions', 'menu-bar', 'devices', 'buttons', 'actions',
  'scrolling', 'direction', 'lines-per-notch', 'wheel-actions', 'pointer', 'profiles', 'settings-file',
  'updates', 'switching-installs', 'uninstall', 'troubleshooting'];
const urlAttributes = ['href', 'src', 'srcset', 'poster', 'data', 'action', 'formaction', 'xlink:href', 'background'];
const idrefAttributes = ['aria-labelledby', 'aria-describedby', 'aria-controls', 'aria-owns', 'for', 'list', 'data-copy'];
const indexBudget = 250 * 1024;

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });
}

function read(name) {
  return fs.readFileSync(path.join(site, name), 'utf8');
}

function decode(value) {
  return value.replace(/&(amp|quot|apos|lt|gt|#39);/g, (_, name) =>
    ({ amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', '#39': "'" })[name]);
}

function parse(html) {
  const source = html.replace(/<!--[\s\S]*?-->/g, '');
  const tags = [];
  for (const match of source.matchAll(/<([a-zA-Z][\w:-]*)((?:"[^"]*"|'[^']*'|[^'">])*)>/g)) {
    const attributes = new Map();
    for (const attr of match[2].matchAll(/([^\s=/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
      attributes.set(attr[1].toLowerCase(), decode(attr[2] ?? attr[3] ?? attr[4] ?? ''));
    }
    tags.push({ name: match[1].toLowerCase(), attributes });
  }
  const scripts = [...source.matchAll(/<script\b((?:"[^"]*"|'[^']*'|[^'">])*)>([\s\S]*?)<\/script\s*>/gi)]
    .map((match) => ({ attributes: match[1], body: match[2] }));
  return { source, tags, scripts };
}

const parsed = new Map(pages.map((page) => [page, parse(read(page))]));

function ids(page) {
  return parsed.get(page).tags.filter((tag) => tag.attributes.has('id')).map((tag) => tag.attributes.get('id'));
}

function meta(page, key) {
  const tag = parsed.get(page).tags.find((t) => t.name === 'meta'
    && (t.attributes.get('name') === key || t.attributes.get('property') === key
      || t.attributes.get('http-equiv')?.toLowerCase() === key.toLowerCase()));
  return tag?.attributes.get('content');
}

function isExternal(url) {
  return /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(url);
}

// Resolves a link on a page to a file in site/ and an optional fragment.
function localTarget(page, url) {
  const hash = url.indexOf('#');
  const fragment = hash === -1 ? '' : decodeURIComponent(url.slice(hash + 1));
  const pathPart = (hash === -1 ? url : url.slice(0, hash)).split('?')[0];
  if (pathPart === '') return { file: page, fragment };
  let file;
  if (pathPart.startsWith('/')) {
    assert.ok(rootRelativePages.has(page), `${page}: use a relative URL instead of ${url} so the site works under /whisker/`);
    assert.ok(pathPart.startsWith('/whisker/'), `${page}: ${url} is outside the project site`);
    file = pathPart.slice('/whisker/'.length);
  } else {
    file = path.posix.join(path.posix.dirname(page), decodeURIComponent(pathPart));
  }
  if (file === '' || file === '.' || file.endsWith('/')) file = path.posix.join(file, 'index.html');
  assert.ok(!file.startsWith('..'), `${page}: ${url} points outside site/`);
  return { file, fragment };
}

function assertResolves(page, url) {
  const { file, fragment } = localTarget(page, url);
  assert.ok(fs.existsSync(path.join(site, file)) && fs.statSync(path.join(site, file)).isFile(),
    `${page}: ${url} points to a missing file (${file})`);
  if (fragment && file.endsWith('.html')) {
    assert.ok(ids(file).includes(fragment), `${page}: ${url} points to a missing anchor in ${file}`);
  }
}

function linkUrls(tag) {
  const urls = [];
  for (const name of urlAttributes) {
    const value = tag.attributes.get(name);
    if (value === undefined) continue;
    if (name === 'srcset') {
      for (const candidate of value.split(',')) urls.push({ name, url: candidate.trim().split(/\s+/)[0] });
    } else {
      urls.push({ name, url: value.trim() });
    }
  }
  return urls.filter(({ url }) => url !== '');
}

function pngSize(file) {
  const bytes = fs.readFileSync(path.join(site, file));
  assert.equal(bytes.subarray(1, 4).toString('latin1'), 'PNG', `${file} is not a PNG`);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), bytes: bytes.length };
}

test('has the files the Pages workflow and inbound links need', () => {
  for (const file of requiredFiles) {
    assert.ok(fs.existsSync(path.join(site, file)), `site/${file} is missing`);
  }
});

test('leaves the update feed to the Pages workflow', () => {
  const feeds = walk(site).filter((file) => path.basename(file).toLowerCase() === 'appcast.xml');
  assert.deepEqual(feeds, [], 'pages.yml copies the signed appcast.xml from the latest release');
});

test('keeps every guide anchor that other places link to', () => {
  const found = ids('guide.html');
  for (const anchor of guideAnchors) assert.ok(found.includes(anchor), `guide.html is missing #${anchor}`);
});

test('uses each id once per page', () => {
  for (const page of pages) {
    const seen = new Set();
    for (const id of ids(page)) {
      assert.ok(!seen.has(id), `${page}: id "${id}" is used more than once`);
      seen.add(id);
    }
  }
});

test('resolves every local link, image, script and stylesheet', () => {
  for (const page of pages) {
    for (const tag of parsed.get(page).tags) {
      for (const { url } of linkUrls(tag)) {
        if (!isExternal(url)) assertResolves(page, url);
      }
    }
  }
});

test('points ARIA, label and copy references at elements on the same page', () => {
  for (const page of pages) {
    const found = new Set(ids(page));
    for (const tag of parsed.get(page).tags) {
      for (const name of idrefAttributes) {
        const value = tag.attributes.get(name);
        if (value === undefined) continue;
        for (const id of value.split(/\s+/).filter(Boolean)) {
          assert.ok(found.has(id), `${page}: ${name}="${value}" refers to a missing id`);
        }
      }
    }
  }
});

test('loads nothing from other sites', () => {
  for (const page of pages) {
    for (const tag of parsed.get(page).tags) {
      const navigation = (tag.name === 'a' || tag.name === 'area')
        || (tag.name === 'link' && tag.attributes.get('rel') === 'canonical');
      for (const { name, url } of linkUrls(tag)) {
        if (!isExternal(url)) continue;
        if (/^mailto:/i.test(url) && navigation) continue;
        assert.ok(/^https:\/\//i.test(url) && navigation && name === 'href',
          `${page}: <${tag.name} ${name}="${url}"> loads from another site`);
      }
    }
  }
  const css = read('site.css').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(css, /@import/i, 'site.css must not import other stylesheets');
  for (const match of css.matchAll(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)/g)) {
    const url = (match[1] ?? match[2] ?? match[3]).trim();
    if (/^data:/i.test(url)) continue;
    assert.ok(!isExternal(url), `site.css loads ${url}`);
    assert.ok(fs.existsSync(path.join(site, url)), `site.css points to a missing file (${url})`);
  }
  const js = read('site.js');
  assert.doesNotMatch(js, /\b(?:fetch|importScripts)\s*\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|\bimport\s*\(/,
    'site.js must not make network requests');
});

test('sets a strict Content Security Policy with nothing inline', () => {
  for (const page of pages) {
    const { source, tags, scripts } = parsed.get(page);
    const csp = meta(page, 'Content-Security-Policy');
    assert.ok(csp, `${page} has no Content-Security-Policy meta tag`);
    const directives = new Map(csp.split(';').map((d) => d.trim().split(/\s+/)).filter((d) => d[0])
      .map(([name, ...sources]) => [name, sources]));
    for (const name of ['default-src', 'script-src', 'style-src']) {
      assert.deepEqual(directives.get(name), ["'self'"], `${page}: ${name} should be 'self'`);
    }
    assert.doesNotMatch(csp, /unsafe-|\*|https?:/, `${page}: the CSP allows too much`);
    assert.doesNotMatch(source, /<style\b/i, `${page} has a <style> element`);
    for (const script of scripts) {
      assert.match(script.attributes, /\bsrc\s*=/, `${page} has an inline <script>`);
      assert.equal(script.body.trim(), '', `${page} has a <script> with a body`);
    }
    for (const tag of tags) {
      for (const name of tag.attributes.keys()) {
        assert.ok(name !== 'style', `${page}: <${tag.name}> has a style attribute`);
        assert.ok(!/^on[a-z]+$/.test(name), `${page}: <${tag.name}> has an inline ${name} handler`);
      }
      for (const { url } of linkUrls(tag)) {
        assert.doesNotMatch(url, /^javascript:/i, `${page} has a javascript: URL`);
      }
    }
  }
});

test('declares the language, colour schemes and viewport', () => {
  for (const page of pages) {
    const html = parsed.get(page).tags.find((tag) => tag.name === 'html');
    assert.ok(html?.attributes.get('lang'), `${page} has no lang attribute`);
    assert.ok(meta(page, 'viewport'), `${page} has no viewport meta tag`);
    assert.equal(meta(page, 'color-scheme'), 'light dark', `${page} has no color-scheme meta tag`);
    assert.ok(meta(page, 'theme-color'), `${page} has no theme-color meta tag`);
  }
});

test('shares absolute, working URLs for previews', () => {
  const siteFile = (url) => {
    assert.ok(url?.startsWith(base), `${url} should start with ${base}`);
    const file = url.slice(base.length).split('#')[0] || 'index.html';
    assert.ok(fs.existsSync(path.join(site, file)), `${url} has no file in site/`);
    return file;
  };
  const image = pngSize('og.png');
  assert.equal(image.width, 1200, 'og.png should be 1200 pixels wide');
  assert.equal(image.height, 630, 'og.png should be 630 pixels high');
  assert.ok(image.bytes < 150 * 1024, 'og.png should stay under 150 KB');
  for (const page of ['index.html', 'guide.html']) {
    const canonical = parsed.get(page).tags.find((tag) => tag.name === 'link' && tag.attributes.get('rel') === 'canonical');
    assert.equal(siteFile(canonical?.attributes.get('href')), page, `${page} has the wrong canonical URL`);
    assert.equal(meta(page, 'og:url'), canonical.attributes.get('href'), `${page}: og:url should match the canonical URL`);
    for (const key of ['og:image', 'twitter:image']) {
      assert.equal(siteFile(meta(page, key)), 'og.png', `${page}: ${key} should be the shared preview image`);
    }
    assert.equal(Number(meta(page, 'og:image:width')), image.width, `${page}: og:image:width doesn't match og.png`);
    assert.equal(Number(meta(page, 'og:image:height')), image.height, `${page}: og:image:height doesn't match og.png`);
  }

  const locations = [...read('sitemap.xml').matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => siteFile(match[1].trim()));
  assert.deepEqual(locations.sort(), ['guide.html', 'index.html']);
  assert.match(read('robots.txt'), new RegExp(`^Sitemap: ${base.replace(/[.]/g, '\\.')}sitemap\\.xml$`, 'm'));
});

test('ships a licence with every self-hosted font', () => {
  const css = read('site.css');
  const licences = fs.readdirSync(path.join(site, 'fonts')).filter((name) => /^OFL-.+\.txt$/.test(name));
  for (const match of css.matchAll(/@font-face\s*{[^}]*font-family:\s*"([^"]+)"/g)) {
    const expected = `OFL-${match[1].replace(/\s+/g, '')}.txt`;
    assert.ok(licences.includes(expected), `site/fonts/${expected} is missing for ${match[1]}`);
  }
});

test('keeps the index page light', () => {
  const { tags } = parsed.get('index.html');
  const files = new Set(['index.html']);
  for (const tag of tags) {
    const rel = tag.attributes.get('rel');
    if (tag.name === 'script' && tag.attributes.has('src')) files.add(localTarget('index.html', tag.attributes.get('src')).file);
    if (tag.name === 'link' && (rel === 'stylesheet' || rel === 'preload')) files.add(localTarget('index.html', tag.attributes.get('href')).file);
  }
  for (const match of read('site.css').matchAll(/url\("?(fonts\/[^")]+)"?\)/g)) files.add(match[1]);
  const total = [...files].reduce((sum, file) => sum + fs.statSync(path.join(site, file)).size, 0);
  assert.ok(total <= indexBudget, `index.html with its CSS, JS and fonts is ${Math.round(total / 1024)} KB`);
});

test('never names other products', () => {
  // Base64 so that this file doesn't name them either.
  const names = new RegExp(Buffer.from('c3RlZXJ8cGxlbnR5Y29tfGN1cnNvcnNlbnNlfGdsaW50fGJhcmJhY2s=', 'base64').toString(), 'i');
  for (const file of walk(site)) {
    assert.doesNotMatch(fs.readFileSync(file, 'latin1'), names, `${path.relative(site, file)} names another product`);
  }
});
