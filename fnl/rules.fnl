;; Path/method/tag filter predicates used when building the merged OpenAPI schema.
;;
;; rules is an array of rule objects. An operation is admitted when it satisfies
;; ALL filters within ANY single rule — rules are OR'd, filters within a rule are AND'd.
;; nil or empty array → allow all.
;;
;; Each rule object (all fields optional):
;;   paths   — path pattern list
;;   methods — method pattern list
;;   tags    — tag pattern list
;;
;; Example — POST to /v1/* with tag "orders" OR any GET:
;;   [{"paths":["/v1/*"],"methods":["POST"],"tags":["orders"]},{"methods":["GET"]}]
;;
;; Pattern syntax:
;;   *        — matches any string
;;   /v1/*    — prefix match (only trailing * is supported)
;;   !pat     — negation: excluded strings always win over inclusions
;;
;; Semantics for a single pattern list:
;;   []           → allow all (not deny all)
;;   ["GET"]      → allow only GET
;;   ["!DELETE"]  → allow everything except DELETE
;;   ["/v1/*", "!/v1/admin/*"] → /v1/* minus /v1/admin/*
;;
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

(fn include-path? [rule path]
  (passes? (or rule.paths []) path))

(fn include-method? [rule method]
  (passes? (or rule.methods []) (method:upper)))

;; Passes when any tag in op-tags matches the tag pattern list.
;; Empty tag config → allow all (tag filter disabled).
(fn include-tag? [rule op-tags]
  (let [tags (or rule.tags [])]
    (if (= (# tags) 0)
      true
      (do
        (var found false)
        (each [_ t (ipairs (or op-tags [])) &until found]
          (when (passes? tags t)
            (set found true)))
        found))))

;; Returns true when path/method/op-tags satisfy all filters in a single rule.
(fn rule-matches? [rule path method op-tags]
  (and (include-path? rule path)
       (include-method? rule method)
       (include-tag? rule op-tags)))

;; An operation is admitted when it satisfies all filters of at least one rule (OR of ANDs).
;; nil or empty rules array → allow all.
(fn allow? [rules path method op-tags]
  (if (or (not rules) (= (# rules) 0))
    true
    (do
      (var matched false)
      (each [_ rule (ipairs rules) &until matched]
        (when (rule-matches? rule path method op-tags)
          (set matched true)))
      matched)))

{:allow? allow?
 :wildcard-match? wildcard-match?
 :matches-any? matches-any?}
