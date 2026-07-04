;; Path/method/tag filter predicates used when building the merged OpenAPI schema.
;;
;; Pattern syntax:
;;   *        — matches any string
;;   /v1/*    — prefix match (only trailing * is supported)
;;   !pat     — negation: excluded strings always win over inclusions
;;
;; Semantics for a single filter list:
;;   []           → allow all (not deny all)
;;   ["GET"]      → allow only GET
;;   ["!DELETE"]  → allow everything except DELETE
;;   ["/v1/*", "!/v1/admin/*"] → /v1/* minus /v1/admin/*
;;
;; allow? ANDs all three filters: path ∩ method ∩ tag.
;; Tag filter passes when any one of the operation's tags matches the tag pattern list.

(fn wildcard-match? [pattern s]
  (if (= pattern "*")
    true
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

;; Split a pattern list into positive includes and negated excludes (!pattern).
(fn split-patterns [patterns]
  (let [includes []
        excludes []]
    (each [_ p (ipairs patterns)]
      (if (= (p:sub 1 1) "!")
        (table.insert excludes (p:sub 2))
        (table.insert includes p)))
    (values includes excludes)))

;; Returns true when s passes a pattern list.
;; Empty list → allow all. Exclusions always win over inclusions.
(fn passes? [patterns s]
  (if (= (# patterns) 0)
    true
    (let [(includes excludes) (split-patterns patterns)]
      (and (not (matches-any? excludes s))
           (or (= (# includes) 0) (matches-any? includes s))))))

(fn include-path? [rules path]
  (passes? (or rules.paths []) path))

(fn include-method? [rules method]
  (passes? (or rules.methods []) (method:upper)))

;; Passes when any tag in op-tags matches the tag pattern list.
;; Empty tag config → allow all (tag filter disabled).
(fn include-tag? [rules op-tags]
  (let [tags (or rules.tags [])]
    (if (= (# tags) 0)
      true
      (do
        (var found false)
        (each [_ t (ipairs (or op-tags [])) &until found]
          (when (passes? tags t)
            (set found true)))
        found))))

(fn allow? [rules path method op-tags]
  (and (include-path? rules path)
       (include-method? rules method)
       (include-tag? rules op-tags)))

{:allow? allow?
 :wildcard-match? wildcard-match?
 :matches-any? matches-any?}
