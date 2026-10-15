/// Throws for the first job, in input order, whose ID was already used by an earlier job.
func checkForDuplicateIDs(_ jobs: [Job]) throws {
    var seenIDs: Set<String> = []
    for job in jobs {
        if seenIDs.contains(job.id) {
            throw TaskProcessorError.duplicateID(job.id)
        }
        seenIDs.insert(job.id)
    }
}
