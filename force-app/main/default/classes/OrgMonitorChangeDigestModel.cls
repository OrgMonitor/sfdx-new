/** Provider-neutral representation of one run and effective actor's changes. */
public inherited sharing class OrgMonitorChangeDigestModel {
    public Id effectiveActorId;
    public String effectiveActorName;
    public Datetime periodStart, periodEnd;
    public String orgTimeZoneSidKey, reviewUrl, correlationId;
    public Integer totalCount = 0, compliantCount = 0, nonCompliantCount = 0;
    public Integer criticalNonCompliantCount = 0, highNonCompliantCount = 0;
    public Integer mediumNonCompliantCount = 0, lowNonCompliantCount = 0;
    public Integer otherNonCompliantCount = 0;
    public List<ReasonSummary> nonComplianceReasons = new List<ReasonSummary>();
    public List<CriticalChangeItem> criticalChanges = new List<CriticalChangeItem>();

    public class ReasonSummary {
        public String reasonCode, windowName, conciseText;
        public Integer count;
    }
    public class CriticalChangeItem {
        public Id changeLogId;
        public String readableOperation, metadataType, componentName, conciseReason;
        public Datetime changeTime;
        public Boolean delegatedAccess;
        public String effectiveActorName, actingAsUserName;
    }
}