;;; anki-org-export.el --- Description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2022 Niklas Loeser
;;
;; Author: Niklas Loeser <niklas@4loeser.net>
;; Maintainer: Niklas Loeser <niklas@4loeser.net>
;; Created: August 31, 2022
;; Modified: August 31, 2022
;; Version: 0.0.1
;; Keywords: abbrev bib c calendar comm convenience data docs emulations extensions faces files frames games hardware help hypermedia i18n internal languages lisp local maint mail matching mouse multimedia news outlines processes terminals tex tools unix vc wp
;; Homepage: https://github.com/niklas/anki-org-export
;; Package-Requires: ((emacs "24.3"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  Description
;;
;;; Code:

(setq org-anki-python-code "rom pathlib import Path
import os
from os import path
from anki.storage import Collection as AnkiCollection
from typing import List, Tuple
from pydantic import BaseModel, Field
import json
import functools
import operator

data = json.loads(data_text)


def diff(a, b, check_renamed_cb):
    \"\"\"a and b are sets. A is from Anki, b not\"\"\"
    added = b - a
    removed = a - b
    same = a & b
    added, removed, renamed = check_renamed_cb(added, removed)
    return same, added, removed, renamed


class CollectionMerger:
    def __init__(self, collection):
        self.collection = collection

    @staticmethod
    def check_renamed(added, removed):
        added = list(added)
        removed = list(removed)
        renamed = []
        i = 0
        while i < len(added):
            added_note = added[i]
            j = 0
            while j < len(removed):
                removed_note = removed[j]
                if added_note.is_note_similar(removed_note):
                    added.pop(i)
                    removed.pop(j)
                    i = i - 1
                    renamed.append((removed_note, added_note))
                    break
                j = j + 1
            i = i + 1
        return added, removed, renamed

    @staticmethod
    def add_deck_recursive(deck, deck_set):
        deck_set.add(deck)
        for child in deck.children:
            CollectionMerger.add_deck_recursive(child, deck_set)

    def get_deck_set(self, decks):
        deck_set = set()
        anki_deck_set = set()
        for deck in decks:
            CollectionMerger.add_deck_recursive(deck, deck_set)
        for deck in self.collection.get_decks():
            CollectionMerger.add_deck_recursive(deck, anki_deck_set)

        return deck_set, anki_deck_set

    def add_added_decks(self, added):
        added = list(added)
        added.sort(key=lambda deck: deck.depth())
        for deck in added:
            parent_id = 0
            if deck.parent is not None:
                if deck.parent.id is not None:
                    parent_id = deck.parent.id
                else:
                    parent_id = self.collection.collection.decks.id_for_name(
                        deck.parent.name
                    )
            id = self.collection.collection.decks.add_normal_deck_with_name(
                deck.name
            ).id
            self.collection.collection.decks.reparent([id], parent_id)
            deck.id = id

    def remove_removed_decks(self, removed):
        removed = list(removed)
        removed.sort(key=lambda deck: deck.depth() * -1)
        removed_ids = list(map(lambda deck: deck.id, removed))
        self.collection.collection.decks.remove(removed_ids)

    def merge_deck_children_recursive(self, deck_children_anki, deck_children):
        for anki_deck in deck_children_anki:
            for deck in deck_children:
                if anki_deck.path() == deck.path():
                    self.merge_deck_recursive(anki_deck, deck)
                    break

    def merge_deck_recursive(self, deck_anki, deck):
        anki_notes = set(deck_anki.notes)
        notes = set(deck.notes)
        _, added, removed, renamed = diff(
            anki_notes, notes, CollectionMerger.check_renamed
        )
        self.collection.add_notes(added, deck_anki.id)
        self.collection.rename_notes(renamed)
        self.collection.remove_notes(removed)
        self.merge_deck_children_recursive(deck_anki.children, deck.children)

    def merge(self, decks):
        deck_set, anki_deck_set = self.get_deck_set(decks)

        def test(a, b):
            return a, b, []

        same, added, removed, renamed = diff(anki_deck_set, deck_set, test)
        self.add_added_decks(added)
        self.merge_deck_children_recursive(collection.get_decks(), decks)
        self.remove_removed_decks(removed)


class AnkiObject(BaseModel):
    id: int = None


class Note(AnkiObject):
    values: Tuple[str, ...]
    type: str

    def __hash__(self):
        return hash((self.values, self.type))

    def __eq__(self, other):
        return other.__hash__() == self.__hash__()

    def is_note_similar(self, other):
        min_length = min(len(self.values), len(other.values))
        for i in range(min_length):
            v1 = self.values[i]
            v2 = other.values[i]
            if v1 == v2:
                return True
        return False


class Deck(AnkiObject):
    notes: List[Note]
    name: str
    children: List[\"Deck\"]
    parent: \"Deck\" = None

    def path(self):
        total_path = ""
        if self.parent is not None:
            total_path = self.parent.path() + chr(31)
        return total_path + self.name

    def depth(self):
        if self.parent is None:
            return 0
        else:
            return self.parent.depth() + 1

    def __hash__(self):
        return hash(self.path())

    def __eq__(self, other):
        return other.__hash__() == self.__hash__()

    @staticmethod
    def load_deck(deck_data, parent=None):
        name = deck_data[\"name\"]

        notes = []
        for table in deck_data[\"tables\"]:
            template = table[\"type\"]
            for card_data in table[\"data\"]:
                note = Note(values=tuple(card_data), type=template)
                notes.append(note)

        deck = Deck(notes=notes, name=name, parent=parent, children=[])

        children = []
        for child_data in deck_data[\"children\"]:
            child = Deck.load_deck(child_data, deck)
            children.append(child)

        deck.children = children
        return deck

    def get_notes_recursive(self):
        if len(self.children) > 0:
            notes = functools.reduce(
                operator.add, [child.get_notes_recursive() for child in self.children]
            )
        else:
            notes = []
        return notes + self.notes


class Collection:
    def __init__(self, user):
        self.collection = Collection.load_collection_from_user(user)

    @staticmethod
    def linux_collection_path(user):
        return path.join(
            Path.home(), \".local\", \"share\", \"Anki2\", user, \"collection.anki2\"
        )

    @staticmethod
    def load_collection_from_user(user):
        # TODO os impl
        path = Collection.linux_collection_path(user)
        return AnkiCollection(path)

    @staticmethod
    def load_decks_from_data(data):
        decks = []
        for deck_data in data:
            deck = Deck.load_deck(deck_data, None)
            decks.append(deck)
        return decks

    def transform_deck(self, deck_tree, parent=None):
        name = deck_tree.name
        id = deck_tree.deck_id
        # cards = collection.get_cards(id)
        notes = self.get_notes(id)
        deck = Deck(id=id, name=name, parent=parent, notes=notes, children=[])
        children = []
        for child_tree in deck_tree.children:
            child = self.transform_deck(child_tree, deck)
            children.append(child)
        deck.children = children
        return deck

    def get_decks(self):
        deck_tree = self.collection.decks.deck_tree()
        children = self.transform_deck(deck_tree).children
        for child in children:
            child.parent = None
        return filter(lambda child: child.name != \"Custom study session\", children)

    def get_notes(self, deck_id):
        anki_cards = [
            self.collection.get_card(card)
            for card in self.collection.find_cards(f\"did:{deck_id}\")
        ]

        notes = []
        for anki_card in anki_cards:
            id = anki_card.id
            anki_note = anki_card.note()
            note_type = anki_note.note_type()
            note = Note(
                values=tuple(anki_note.fields), id=anki_note.id, type=note_type[\"name\"]
            )
            notes.append(note)
        return notes

    def add_notes(self, notes, deck_id):
        for note in notes:
            template_id = self.collection.models.id_for_name(note.type)
            anki_note = self.collection.new_note(template_id)
            anki_note.fields = note.values
            self.collection.add_note(anki_note, deck_id)

    def remove_notes(self, notes):
        self.collection.remove_notes(list(map(lambda note: note.id, notes)))

    def rename_notes(self, notes):
        for note in notes:
            anki_note = note[0]
            new_note = note[1]
            template_id = self.collection.models.id_for_name(new_note.type)
            anki_note = self.collection.get_note(anki_note.id)
            anki_note.fields = new_note.values
            anki_note.mid = template_id
            self.collection.update_note(anki_note)

    def save(self):
        self.collection.save()


def get_all_cards(collection, deck_tree, out_dict):
    out_dict[deck_tree.deck_id] = get_cards(collection, deck_tree.deck_id)
    for child in deck_tree.children:
        get_all_cards(collection, child, out_dict)


collection = Collection(\"User 1\")
merger = CollectionMerger(collection)
merger.merge(Collection.load_decks_from_data(data))
collection.save()
")

(defun org-anki-parse-table-cell (cell)
  ""
  (let* ((start (org-element-property :contents-begin cell))
         (end (org-element-property :contents-end cell)))
    (buffer-substring start end)))

(defun org-anki-table-rows (table)
  ""
  (cdr
  (cdr
   (org-element-map table 'table-row
     (lambda (row)
       (apply #'vector
              (org-element-map row 'table-cell #'org-anki-parse-table-cell)))))))

(defun org-anki-parse-tables (tree)
  ""
  (org-element-map (org-element-contents tree) 'table
    (lambda (table)
      `((type . ,(or (car (org-element-property :attr_anki_template table)) "Basic"))
        (data . ,(org-anki-table-rows table))))
    nil nil 'headline))

(defun org-anki-parse-headline (headline level)
  ""
  `((name . ,(org-element-property :raw-value headline))
    (tables . ,(apply #'vector (org-anki-parse-tables headline)))
    (children . ,(apply #'vector
                        (org-anki-parse-tree headline (+ 1 level))))))


(defun org-anki-element-find-property (element key)
  ""
  (org-element-map element 'keyword
    (lambda (keyword)
      (when (string= (org-element-property :key keyword) key)
                             (org-element-property :value keyword)))))

(defun org-anki-parse-tree (tree level)
  ""
  (org-element-map tree 'headline
    (lambda (headline)
      (when (eq level (org-element-property :level headline))
        (org-anki-parse-headline headline level)))))

(defun org-anki-to-json ()
    "Export the current buffer to JSON. Only headlines and tables will be exported."
    (json-encode (org-anki-parse-tree (org-element-parse-buffer) 1)))

(defun org-anki-export ()
  ""
  (interactive)
  (org-babel-python-evaluate-external-process org-anki-python-code 'value nil (concat "data=" (org-anki-to-json))))
(provide 'anki-org-export)
;;; anki-org-export.el ends here
