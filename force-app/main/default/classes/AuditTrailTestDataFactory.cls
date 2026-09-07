/**
 * AuditTrailTestDataFactory
 *
 * Utility class for building SObjects used in audit trail test classes.
 *
 * Design notes:
 * - SetupAuditTrail is a read-only system table — cannot be inserted in tests.
 *   We simulate it by building mock SObjects via Schema.getGlobalDescribe()
 *   and populating fields via put(), then passing them directly to service methods.
 * - Custom Metadata records cannot be created in tests; the metadata service
 *   caches are injected via @TestVisible static fields.
 * - Deployment_Window__c and Audit_Trail__c CAN be inserted in tests (custom objects).
 */
@IsTest
public class AuditTrailTestDataFactory {

    // ── Simulated SetupAuditTrail SObject ─────────────────────────────────────
    /**
     * Creates an in-memory SObject that mimics a SetupAuditTrail row.
     *
     * SetupAuditTrail is a read-only system table — it cannot be inserted in tests
     * and its system fields (CreatedDate, CreatedById) cannot be set via SObject.put()
     * because Apex enforces field-writability at that layer too.
     *
     * JSON deserialization is the only supported Salesforce pattern for populating
     * read-only system fields on an in-memory SObject for unit testing.
     */
    public static SObject makeSatRecord(
            String action, String section, String display,
            Id createdById, DateTime createdDate) {

        // Serialize the field map — JSON.serialize handles DateTime formatting.
        Map<String, Object> fields = new Map<String, Object>{
            'attributes'  => new Map<String, Object>{ 'type' => 'SetupAuditTrail' },
            'Action'      => action,
            'Section'     => section,
            'Display'     => display,
            'CreatedById' => String.valueOf(createdById),
            'CreatedDate' => createdDate
        };
        return (SetupAuditTrail) JSON.deserialize(
            JSON.serialize(fields), SetupAuditTrail.class);
    }

    // ── Deployment_Window__c ──────────────────────────────────────────────────
    public static Deployment_Window__c makeDeploymentWindow(
            DateTime startDt, DateTime endDt, String status) {

        return new Deployment_Window__c(
            Start_Date_Time__c = startDt,
            End_Date_Time__c   = endDt,
            Status__c          = status
        );
    }

    public static Deployment_Window__c insertDeploymentWindow(
            DateTime startDt, DateTime endDt, String status) {

        Deployment_Window__c dw = makeDeploymentWindow(startDt, endDt, status);
        insert dw;
        return dw;
    }

    // ── Audit_Trail_Config DTO ────────────────────────────────────────────────
    public static AuditTrailMetadataService.AuditTrailConfig makeConfig(DateTime lastRun) {
        AuditTrailMetadataService.AuditTrailConfig cfg =
            new AuditTrailMetadataService.AuditTrailConfig();
        cfg.lastRunTimestamp = lastRun;
        return cfg;
    }

    // ── Severity Rules ────────────────────────────────────────────────────────
    public static List<AuditTrailMetadataService.SeverityRule> makeSeverityRules() {
        List<AuditTrailMetadataService.SeverityRule> rules =
            new List<AuditTrailMetadataService.SeverityRule>();

        AuditTrailMetadataService.SeverityRule critical = new AuditTrailMetadataService.SeverityRule();
        critical.developerName = 'Critical_Pattern';
        critical.regexPattern  = '.*[Dd]elete.*';
        critical.section       = null;
        critical.severityValue = 'CRITICAL';
        critical.sortOrder     = 1;
        critical.active        = true;
        rules.add(critical);

        AuditTrailMetadataService.SeverityRule high = new AuditTrailMetadataService.SeverityRule();
        high.developerName = 'High_Pattern';
        high.regexPattern  = '.*[Cc]reated.*[Aa]pex.*';
        high.section       = 'Apex Classes';
        high.severityValue = 'HIGH';
        high.sortOrder     = 2;
        high.active        = true;
        rules.add(high);

        AuditTrailMetadataService.SeverityRule low = new AuditTrailMetadataService.SeverityRule();
        low.developerName = 'Low_Pattern';
        low.regexPattern  = '.*';
        low.section       = null;
        low.severityValue = 'LOW';
        low.sortOrder     = 999;
        low.active        = true;
        rules.add(low);

        return rules;
    }

    // ── DeploymentWindowSchema DTO ────────────────────────────────────────────
    public static AuditTrailMetadataService.DeploymentWindowSchema makeDwSchema() {
        AuditTrailMetadataService.DeploymentWindowSchema schema =
            new AuditTrailMetadataService.DeploymentWindowSchema();
        schema.objectApiName   = 'Deployment_Window__c';
        schema.startField      = 'Start_Date_Time__c';
        schema.endField        = 'End_Date_Time__c';
        schema.statusField     = 'Status__c';
        schema.activeValue     = 'Active';
        schema.isStatusBoolean = false;
        return schema;
    }

    // ── ComplianceResult DTO ──────────────────────────────────────────────────
    public static AuditTrailComplianceService.ComplianceResult makeCompliant(Id windowId) {
        AuditTrailComplianceService.ComplianceResult cr =
            new AuditTrailComplianceService.ComplianceResult();
        cr.label    = AuditTrailConstants.COMPLIANT;
        cr.windowId = windowId;
        return cr;
    }

    public static AuditTrailComplianceService.ComplianceResult makeNonCompliant() {
        AuditTrailComplianceService.ComplianceResult cr =
            new AuditTrailComplianceService.ComplianceResult();
        cr.label    = AuditTrailConstants.NON_COMPLIANT;
        cr.windowId = null;
        return cr;
    }
}