import Foundation

/// Converts a ``SmartNoteQuery`` to and from `NSPredicate`, the only place the
/// AppKit rule-builder (`NSPredicateEditor`) and our stable on-disk AST meet.
/// `NSPredicate`/`NSComparisonPredicate`/`NSCompoundPredicate`/`NSExpression`
/// are Foundation (not AppKit), so this bridge — and its round-trip fidelity —
/// lives and is unit-tested in Core; only the literal editor row templates need
/// AppKit and stay in the App layer.
///
/// The bridge is symmetric by construction:
/// - Comparisons map onto `NSComparisonPredicate` with a keyPath left, a
///   constant right, and a directly-mapped operator.
/// - Existence (`is set` / `is empty`) uses an `NSNull` constant sentinel, so it
///   never collides with a real `!=`/`==` on a string.
/// - AND / OR / NOT map onto `NSCompoundPredicate`.
///
/// Nothing evaluates the produced `NSPredicate`; ``SmartNoteEvaluator`` owns
/// evaluation. The predicate exists purely to drive the editor UI.
public enum SmartNotePredicateBridge {

    // MARK: - AST → NSPredicate

    public static func makePredicate(_ query: SmartNoteQuery) -> NSPredicate {
        makePredicate(query.root)
    }

    public static func makePredicate(_ node: SmartNotePredicate) -> NSPredicate {
        switch node {
        case .comparison(let comparison):
            return makeComparison(comparison)
        case .and(let children):
            return NSCompoundPredicate(andPredicateWithSubpredicates: children.map(makePredicate))
        case .or(let children):
            return NSCompoundPredicate(orPredicateWithSubpredicates: children.map(makePredicate))
        case .not(let child):
            return NSCompoundPredicate(notPredicateWithSubpredicate: makePredicate(child))
        }
    }

    private static func makeComparison(_ comparison: SmartNoteComparison) -> NSComparisonPredicate {
        let left = NSExpression(forKeyPath: keyPath(for: comparison.field))
        let right: NSExpression
        let type: NSComparisonPredicate.Operator

        if comparison.op.isExistence {
            right = NSExpression(forConstantValue: NSNull())
            type = comparison.op == .exists ? .notEqualTo : .equalTo
        } else {
            right = constantExpression(comparison.value)
            type = operatorType(comparison.op)
        }

        return NSComparisonPredicate(
            leftExpression: left,
            rightExpression: right,
            modifier: .direct,
            type: type,
            options: comparison.field.isDate ? [] : [.caseInsensitive]
        )
    }

    private static func constantExpression(_ value: SmartNoteValue) -> NSExpression {
        switch value {
        case .text(let string):
            return NSExpression(forConstantValue: string)
        case .status(let status):
            return NSExpression(forConstantValue: status.rawValue)
        case .date(let date):
            return NSExpression(forConstantValue: dateConstant(date))
        case .empty:
            return NSExpression(forConstantValue: NSNull())
        }
    }

    /// Absolute dates ride as real `Date` constants (an editor date picker);
    /// relative anchors ride as reserved token strings.
    private static func dateConstant(_ date: SmartNoteDate) -> Any {
        switch date {
        case .absolute(let instant): return instant
        case .today: return "\(relativeTokenPrefix)today"
        case .startOfWeek: return "\(relativeTokenPrefix)startOfWeek"
        case .endOfWeek: return "\(relativeTokenPrefix)endOfWeek"
        case .daysFromToday(let offset): return "\(relativeTokenPrefix)days:\(offset)"
        }
    }

    // MARK: - NSPredicate → AST

    public static func makeQuery(
        from predicate: NSPredicate,
        version: Int = SmartNoteQuery.currentVersion
    ) throws -> SmartNoteQuery {
        SmartNoteQuery(root: try makeNode(from: predicate), version: version)
    }

    public static func makeNode(from predicate: NSPredicate) throws -> SmartNotePredicate {
        if let compound = predicate as? NSCompoundPredicate {
            let children = try (compound.subpredicates as? [NSPredicate] ?? []).map(makeNode)
            switch compound.compoundPredicateType {
            case .and: return .and(children)
            case .or: return .or(children)
            case .not:
                guard let first = children.first else { throw SmartNotePredicateBridgeError.unrepresentable }
                return .not(first)
            @unknown default:
                throw SmartNotePredicateBridgeError.unrepresentable
            }
        }
        if let comparison = predicate as? NSComparisonPredicate {
            return .comparison(try makeComparison(from: comparison))
        }
        throw SmartNotePredicateBridgeError.unrepresentable
    }

    private static func makeComparison(from predicate: NSComparisonPredicate) throws -> SmartNoteComparison {
        // `.keyPath` raises on a non-keyPath expression, so gate on the type.
        guard predicate.leftExpression.expressionType == .keyPath,
              let field = field(forKeyPath: predicate.leftExpression.keyPath) else {
            throw SmartNotePredicateBridgeError.unrepresentable
        }
        let constant = predicate.rightExpression.constantValue

        // Existence sentinel: an NSNull constant means is-set / is-empty.
        if constant is NSNull {
            let op: SmartNoteOperator = predicate.predicateOperatorType == .notEqualTo ? .exists : .notExists
            return SmartNoteComparison(field, op, .empty)
        }

        guard let op = smartOperator(for: predicate.predicateOperatorType) else {
            throw SmartNotePredicateBridgeError.unrepresentable
        }
        return SmartNoteComparison(field, op, try value(for: field, constant: constant))
    }

    private static func value(for field: SmartNoteField, constant: Any?) throws -> SmartNoteValue {
        if field == .status, let raw = constant as? String, let status = PropsStatus(rawValue: raw) {
            return .status(status)
        }
        if field.isDate {
            if let date = constant as? Date {
                return .date(.absolute(date))
            }
            if let token = constant as? String, let date = relativeDate(fromToken: token) {
                return .date(date)
            }
            throw SmartNotePredicateBridgeError.unrepresentable
        }
        if let string = constant as? String {
            return .text(string)
        }
        throw SmartNotePredicateBridgeError.unrepresentable
    }

    // MARK: - KeyPath mapping

    private static let frontmatterPrefix = "frontmatter."

    static func keyPath(for field: SmartNoteField) -> String {
        switch field {
        case .tag: return "tag"
        case .status: return "status"
        case .scheduled: return "scheduled"
        case .due: return "due"
        case .created: return "created"
        case .modified: return "modified"
        case .fullText: return "text"
        case .path: return "path"
        case .title: return "title"
        case .property(let key): return "\(frontmatterPrefix)\(key)"
        }
    }

    static func field(forKeyPath keyPath: String) -> SmartNoteField? {
        if keyPath.hasPrefix(frontmatterPrefix) {
            return .property(key: String(keyPath.dropFirst(frontmatterPrefix.count)))
        }
        switch keyPath {
        case "tag": return .tag
        case "status": return .status
        case "scheduled": return .scheduled
        case "due": return .due
        case "created": return .created
        case "modified": return .modified
        case "text": return .fullText
        case "path": return .path
        case "title": return .title
        default: return nil
        }
    }

    // MARK: - Operator mapping

    private static func operatorType(_ op: SmartNoteOperator) -> NSComparisonPredicate.Operator {
        switch op {
        case .equalTo: return .equalTo
        case .notEqualTo: return .notEqualTo
        case .lessThan: return .lessThan
        case .lessThanOrEqualTo: return .lessThanOrEqualTo
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqualTo: return .greaterThanOrEqualTo
        case .contains: return .contains
        case .beginsWith: return .beginsWith
        case .exists: return .notEqualTo   // paired with NSNull sentinel
        case .notExists: return .equalTo   // paired with NSNull sentinel
        }
    }

    private static func smartOperator(for type: NSComparisonPredicate.Operator) -> SmartNoteOperator? {
        switch type {
        case .equalTo: return .equalTo
        case .notEqualTo: return .notEqualTo
        case .lessThan: return .lessThan
        case .lessThanOrEqualTo: return .lessThanOrEqualTo
        case .greaterThan: return .greaterThan
        case .greaterThanOrEqualTo: return .greaterThanOrEqualTo
        case .contains: return .contains
        case .beginsWith: return .beginsWith
        default: return nil
        }
    }

    // MARK: - Relative date tokens

    private static let relativeTokenPrefix = "$relative$"

    private static func relativeDate(fromToken token: String) -> SmartNoteDate? {
        guard token.hasPrefix(relativeTokenPrefix) else { return nil }
        let body = String(token.dropFirst(relativeTokenPrefix.count))
        switch body {
        case "today": return .today
        case "startOfWeek": return .startOfWeek
        case "endOfWeek": return .endOfWeek
        default:
            let daysPrefix = "days:"
            if body.hasPrefix(daysPrefix), let offset = Int(body.dropFirst(daysPrefix.count)) {
                return .daysFromToday(offset)
            }
            return nil
        }
    }
}

/// Failure converting an `NSPredicate` that doesn't fit the smart-note schema.
public enum SmartNotePredicateBridgeError: Error, Equatable, Sendable {
    case unrepresentable
}
