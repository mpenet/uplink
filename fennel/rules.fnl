(fn wildcard-match? [pattern s]
  (if (= pattern "*")
    true
    ;; simple prefix wildcard: /foo/* matches /foo/bar/baz
    (let [star-pos (pattern:find "*" 1 true)]
      (if star-pos
        (let [prefix (pattern:sub 1 (- star-pos 1))]
          (= (s:sub 1 (# prefix)) prefix))
        (= pattern s)))))

(fn matches-any? [patterns s]
  (var found false)
  (each [_ p (ipairs patterns) &until found]
    (when (wildcard-match? p s)
      (set found true)))
  found)

(fn include-path? [rules path]
  (let [inc (or rules.include_paths ["*"])]
    (if (= (# inc) 0)
      true
      (matches-any? inc path))))

(fn exclude-path? [rules path]
  (let [exc (or rules.exclude_paths [])]
    (matches-any? exc path)))

(fn include-method? [rules method]
  (let [inc (or rules.include_methods [])]
    (if (= (# inc) 0)
      true
      (matches-any? inc (method:upper)))))

(fn include-tag? [rules op-tags]
  (let [inc (or rules.include_tags [])]
    (if (= (# inc) 0)
      true
      (do
        (var found false)
        (each [_ t (ipairs (or op-tags [])) &until found]
          (when (matches-any? inc t)
            (set found true)))
        found))))

;; Returns true if this operation (path + method + tags) passes the service rules.
(fn allow? [rules path method op-tags]
  (and (include-path? rules path)
       (not (exclude-path? rules path))
       (include-method? rules method)
       (include-tag? rules op-tags)))

{:allow? allow?
 :wildcard-match? wildcard-match?
 :matches-any? matches-any?}
