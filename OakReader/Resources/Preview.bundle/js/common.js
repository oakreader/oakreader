/**
 * OakReader Preview Utilities (adapted from MiaoYan)
 */

const OakPreview = {
  isDarkMode() {
    return document.documentElement.classList.contains('darkmode');
  },

  setupTextSelection() {
    function getSelectionAndSendMessage() {
      const txt = document.getSelection().toString();
      window.webkit?.messageHandlers.newSelectionDetected?.postMessage(txt);
    }

    document.onmouseup = getSelectionAndSendMessage;
    document.onkeyup = getSelectionAndSendMessage;
    document.oncontextmenu = getSelectionAndSendMessage;
  },

  setupCheckboxes() {
    document.querySelectorAll('input').forEach(input => {
      input.disabled = true;

      const parent = input.parentNode;
      const grandParent = parent?.parentNode;

      if (parent?.tagName === 'P' && grandParent?.tagName === 'LI') {
        grandParent.parentNode?.classList.add('cb');
      } else if (parent?.tagName === 'LI') {
        grandParent?.classList.add('cb');
      }
    });
  },

  setupInteractiveCheckboxes() {
    this.setupCheckboxes();

    const checkboxList = document.querySelectorAll('input[type=checkbox]');
    checkboxList.forEach((checkbox, i) => {
      if (checkbox.parentNode.nodeName === 'LI' && checkbox.hasAttribute('checked')) {
        checkbox.parentNode.classList.add('strike');
      }

      checkbox.disabled = false;
      checkbox.dataset.checkbox = i;

      checkbox.addEventListener('click', (event) => {
        this.handleCheckboxClick(event.target);
      });
    });
  },

  handleCheckboxClick(element) {
    if (element.parentNode.nodeName === 'LI') {
      element.parentNode.classList.remove('strike');
    }

    const id = element.dataset.checkbox;
    if (window.webkit?.messageHandlers.checkbox) {
      window.webkit.messageHandlers.checkbox.postMessage(id);
    }

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.dataset.checkbox = id;

    if (!element.hasAttribute('checked')) {
      input.defaultChecked = true;
      if (element.parentNode.nodeName === 'LI') {
        element.parentNode.classList.add('strike');
      }
    }

    element.parentNode.replaceChild(input, element);
    input.addEventListener('click', () => {
      this.handleCheckboxClick(input);
    });
  },

  optimizeImages() {
    const allImages = document.querySelectorAll('img');

    allImages.forEach((img) => {
      img.style.maxWidth = '100%';
      img.style.height = 'auto';

      if (!img.classList.contains('lazy-image')) {
        img.setAttribute('loading', 'eager');
      }
    });
  },

  setupImageZoom() {
    const zoomImgs = document.querySelectorAll('#write>img, #write>p>img, #write>table img');
    if (zoomImgs.length > 0 && window.Lightense) {
      window.Lightense(zoomImgs, {
        background: this.isDarkMode() ? 'rgba(33, 38, 43, .8)' : 'rgba(255, 255, 255, .8)',
      });
    }
  },

  setupHeaderAnchors() {
    const usedIds = new Set();
    document.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach((h) => {
      let baseId = h.innerText.trim();
      let id = baseId;
      let counter = 1;

      while (usedIds.has(id)) {
        id = `${baseId}-${counter}`;
        counter++;
      }

      h.id = id;
      usedIds.add(id);
    });

    document.querySelectorAll('a[href^="#"]').forEach((anchor) => {
      anchor.addEventListener('click', function (e) {
        e.preventDefault();
        document.querySelector(decodeURIComponent(this.getAttribute('href')))?.scrollIntoView({
          behavior: 'smooth',
        });
      });
    });
  },

  setupReferenceLinks() {
    document.querySelectorAll('a[href^="oak-ref://"]').forEach((anchor) => {
      anchor.addEventListener('click', function (e) {
        e.preventDefault();
        const ref = decodeURIComponent(this.getAttribute('href').replace('oak-ref://', ''));
        window.webkit?.messageHandlers.oakRef?.postMessage(ref);
      });
    });
  },

  initializeCore() {
    if (window.hljs) {
      hljs.configure({ cssSelector: 'pre code' });
      hljs.highlightAll();
    }

    this.escapeCurrencyLikeMath();
  },

  escapeCurrencyLikeMath() {
    const writeElement = document.getElementById('write');
    if (!writeElement) return;

    const walker = document.createTreeWalker(
      writeElement,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (!node.textContent.includes('$')) return NodeFilter.FILTER_REJECT;

          let parent = node.parentElement;
          while (parent && parent !== writeElement) {
            const tagName = parent.tagName;
            if (tagName === 'CODE' || tagName === 'PRE' || tagName === 'SCRIPT' || tagName === 'STYLE' ||
                parent.classList.contains('katex') || parent.classList.contains('skip-math-dollar')) {
              return NodeFilter.FILTER_REJECT;
            }
            parent = parent.parentElement;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      }
    );

    const nodesToUpdate = [];
    let currentNode;
    while ((currentNode = walker.nextNode())) {
      nodesToUpdate.push(currentNode);
    }

    const currencyRegex = /^\$([0-9]+(?:[.,][0-9]+)?)(?=$|[^0-9A-Za-z+\-*/=<>^_\\])/;

    nodesToUpdate.forEach(node => {
      const text = node.textContent;
      if (!text.includes('$')) return;

      const fragment = document.createDocumentFragment();
      let index = 0;
      let lastIndex = 0;
      let replaced = false;

      while (index < text.length) {
        const char = text[index];

        if (char === '\\' && index + 1 < text.length && text[index + 1] === '$') {
          index += 2;
          continue;
        }

        if (char === '$') {
          const remaining = text.slice(index);
          const match = remaining.match(currencyRegex);
          if (match) {
            if (index > lastIndex) {
              fragment.appendChild(document.createTextNode(text.slice(lastIndex, index)));
            }
            const span = document.createElement('span');
            span.className = 'skip-math-dollar';
            span.textContent = match[0];
            fragment.appendChild(span);
            index += match[0].length;
            lastIndex = index;
            replaced = true;
            continue;
          }
        }
        index += 1;
      }

      if (!replaced) return;

      if (lastIndex < text.length) {
        fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
      }
      node.parentNode?.replaceChild(fragment, node);
    });
  }
};

window.OakPreview = OakPreview;
