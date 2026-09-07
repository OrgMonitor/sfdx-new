/**
 * AuditTrailComplianceService
 *
 * Determines deployment window compliance for each SetupAuditTrail record.
 * A record is COMPLIANT if its CreatedDate falls within at least one active
 * Deployment_Window__c record; otherwise NON_COMPLIANT.
 *
 * Field names on Deployment_Window__c (start, end, status) are received via
 * the schema descriptor resolved by AuditTrailMetadataService — never hardcoded.
 */
public with sharing class AuditTrailComplianceService {

    // ── Evaluation Result ─────────────────────────────────────────────────────
    public class ComplianceResult {
        public String  label;       // 'Compliant' or 'Non-Compliant'
        public Id      windowId;    // Id of matched window (null if non-compliant)
    }

    // ── Main Evaluation ───────────────────────────────────────────────────────

    /**
     * Evaluates compliance for a batch of SetupAuditTrail SObjects against
     * pre-fetched deployment window records.
     *
     * @param satRecords  — list of SetupAuditTrail SObjects from the batch scope
     * @param dwWindows   — pre-fetched active Deployment_Window__c SObjects
     * @param dwSchema    — runtime-resolved field names for dwWindows
     * @return Map keyed by SetupAuditTrail Id → ComplianceResult
     */
    public Map<Id, ComplianceResult> evaluate(
            List<SObject>                                   satRecords,
            List<SObject>                                   dwWindows,
            AuditTrailMetadataService.DeploymentWindowSchema dwSchema) {

        Map<Id, ComplianceResult> results = new Map<Id, ComplianceResult>();
        if (satRecords == null || satRecords.isEmpty()) return results;

        // Pre-build window intervals for O(n·m) traversal without re-casting
        List<WindowInterval> intervals = buildIntervals(dwWindows, dwSchema);

        for (SObject satRec : satRecords) {
            Id       satId      = (Id)       satRec.get(AuditTrailConstants.SAT_ID);
            DateTime satCreated = (DateTime) satRec.get(AuditTrailConstants.SAT_CREATED_DATE);

            ComplianceResult cr = new ComplianceResult();
            cr.label    = AuditTrailConstants.NON_COMPLIANT;
            cr.windowId = null;

            if (satCreated != null && !intervals.isEmpty()) {
                for (WindowInterval wi : intervals) {
                    if (wi.start != null && wi.windowEnd != null
                            && satCreated >= wi.start && satCreated <= wi.windowEnd) {
                        cr.label    = AuditTrailConstants.COMPLIANT;
                        cr.windowId = wi.windowId;
                        break;
                    }
                }
            }

            results.put(satId, cr);
        }
        return results;
    }

    // ── Private Helpers ───────────────────────────────────────────────────────

    private List<WindowInterval> buildIntervals(
            List<SObject>                                    dwWindows,
            AuditTrailMetadataService.DeploymentWindowSchema dwSchema) {

        List<WindowInterval> intervals = new List<WindowInterval>();
        if (dwWindows == null || dwWindows.isEmpty() || dwSchema == null) return intervals;

        for (SObject dw : dwWindows) {
            Object startRaw = dw.get(dwSchema.startField);
            Object endRaw   = dw.get(dwSchema.endField);

            if (startRaw == null || endRaw == null) continue;

            WindowInterval wi = new WindowInterval();
            wi.windowId   = (Id) dw.get('Id');
            wi.start      = (DateTime) startRaw;
            wi.windowEnd  = (DateTime) endRaw;
            intervals.add(wi);
        }
        return intervals;
    }

    private class WindowInterval {
        public Id       windowId;
        public DateTime start;
        public DateTime windowEnd;
    }
}