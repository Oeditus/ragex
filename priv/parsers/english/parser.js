#!/usr/bin/env node
/**
 * English & Prose CST Parser for Metastatic
 * 
 * Parses English natural language text into a Concrete Syntax Tree (CST)
 * with sentences, clauses, tokens, and punctuation.
 */

const fs = require('fs');

function parseEnglish(source) {
  try {
    const paragraphs = source.split(/\n\s*\n/).filter(p => p.trim().length > 0);
    
    let currentLine = 1;
    let currentCol = 1;

    const parsedParagraphs = paragraphs.map((paraText, pIdx) => {
      // Split into sentences (simple sentence boundary disambiguation)
      const sentenceRegex = /[^.!?]+[.!?]+(\s+|$)|[^.!?]+$/g;
      const sentenceMatches = paraText.match(sentenceRegex) || [paraText];

      const sentences = sentenceMatches.map((sentText, sIdx) => {
        const trimmedSent = sentText.trim();
        // Tokenize words and punctuation
        const tokenRegex = /([A-Za-z0-9]+(?:'[A-Za-z]+)?|[-–—]|[:;,.!?(){}[\]"“”'’])/g;
        let match;
        const tokens = [];

        while ((match = tokenRegex.exec(trimmedSent)) !== null) {
          const raw = match[0];
          const isPunct = /^[:;,.!?(){}[\]"“”'’\-–—]$/.test(raw);
          tokens.push({
            type: isPunct ? 'punctuation' : 'word',
            value: raw,
            line: currentLine,
            col: match.index + 1
          });
        }

        return {
          type: 'sentence',
          text: trimmedSent,
          children: tokens
        };
      });

      return {
        type: 'paragraph',
        children: sentences
      };
    });

    return {
      ok: true,
      ast: {
        type: 'document',
        language: 'en',
        children: parsedParagraphs
      }
    };
  } catch (err) {
    return {
      ok: false,
      error: {
        type: 'ParserError',
        msg: err.message
      }
    };
  }
}

function main() {
  let source = '';
  let inputFile = null;
  let treeSitterBin = process.env.TREE_SITTER_BIN || 'tree-sitter';

  for (let i = 2; i < process.argv.length; i++) {
    if (process.argv[i] === '--tree-sitter-bin' && process.argv[i + 1]) {
      treeSitterBin = process.argv[i + 1];
      i++;
    } else if (!inputFile && fs.existsSync(process.argv[i])) {
      inputFile = process.argv[i];
    }
  }

  if (inputFile) {
    source = fs.readFileSync(inputFile, 'utf-8');
  } else {
    source = fs.readFileSync(0, 'utf-8');
  }

  const result = parseEnglish(source, treeSitterBin);
  process.stdout.write(JSON.stringify(result));
}

main();
