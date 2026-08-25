import Foundation

public extension HostV6 {
    struct MergeOutcome<Entity: HostV6SyncedEntity>: Sendable {
        public var selected: Entity
        public var review: MergeReview?

        public init(selected: Entity, review: MergeReview?) {
            self.selected = selected
            self.review = review
        }
    }

    enum MergeEngine {
        public static func merge<Entity: HostV6SyncedEntity>(
            _ left: Entity,
            _ right: Entity
        ) -> MergeOutcome<Entity> {
            precondition(left.entityReference == right.entityReference, "Cannot merge different entities")
            switch left.stamp.compared(to: right.stamp) {
            case .before:
                return MergeOutcome(selected: right, review: nil)
            case .after:
                return MergeOutcome(selected: left, review: nil)
            case .equal:
                guard left == right else { return conflicting(left, right) }
                return MergeOutcome(selected: left, review: nil)
            case .concurrent:
                return conflicting(left, right)
            }
        }

        private static func conflicting<Entity: HostV6SyncedEntity>(
            _ left: Entity,
            _ right: Entity
        ) -> MergeOutcome<Entity> {
            let selected = concurrentSelection(left, right)
            let reference = left.entityReference
            let candidates = [left, right]
                .map {
                    MergeCandidate(
                        mutationID: $0.stamp.mutationID,
                        vector: $0.stamp.vector,
                        isDeleted: $0.deletedAt != nil,
                        summaryFields: $0.mergeCandidateFields
                    )
                }
                .sorted { $0.mutationID.uuidString < $1.mutationID.uuidString }
            let reviewID = StableID.mergeReview(
                entityType: reference.entityType,
                entityID: reference.stableID,
                conflictingMutationIDs: candidates.map(\.mutationID)
            )
            let review = MergeReview(
                id: reviewID,
                entityType: reference.entityType,
                entityID: reference.stableID,
                candidates: candidates,
                isBlocking: isBlockingConflict(left, right),
                stamp: SyncStamp(
                    vector: SyncStamp.join(left.stamp.vector, right.stamp.vector),
                    mutationID: reviewID,
                    updatedAt: max(left.stamp.updatedAt, right.stamp.updatedAt)
                )
            )
            return MergeOutcome(selected: selected, review: review)
        }

        private static func deterministicSelection<Entity: HostV6SyncedEntity>(
            _ left: Entity,
            _ right: Entity
        ) -> Entity {
            if left.deletedAt != nil, right.deletedAt == nil { return left }
            if right.deletedAt != nil, left.deletedAt == nil { return right }
            return left.stamp.mutationID.uuidString < right.stamp.mutationID.uuidString ? left : right
        }

        private static func concurrentSelection<Entity: HostV6SyncedEntity>(
            _ left: Entity,
            _ right: Entity
        ) -> Entity {
            deterministicSelection(left, right)
        }

        private static func isBlockingConflict<Entity: HostV6SyncedEntity>(
            _ left: Entity,
            _ right: Entity
        ) -> Bool {
            guard left.entityReference.entityType == .host,
                  left.deletedAt == nil,
                  right.deletedAt == nil else {
                return true
            }
            let keys = Set(left.mergeCandidateFields.keys).union(right.mergeCandidateFields.keys)
            let changedKeys = Set(keys.filter { left.mergeCandidateFields[$0] != right.mergeCandidateFields[$0] })
            return changedKeys.isEmpty || !changedKeys.isSubset(of: ["name", "group"])
        }
    }
}
