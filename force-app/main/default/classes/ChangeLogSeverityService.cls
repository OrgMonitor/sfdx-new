public class ChangeLogSeverityService {

    // Cache the map for the transaction (avoid repeated SOQL)
    private static Map<String, String> severityMap;
    private static List<Audit_Severity__mdt > cachedPatterns;
	private static Map<String, Audit_Severity__mdt> severityByAction;
    
    public static Map<String, String> getSeverityMap() {
        if (severityMap == null) {
            severityMap = new Map<String, String>();
            for (Audit_Severity__mdt record : [
                SELECT MasterLabel, Severity__c
                FROM Audit_Severity__mdt
            ]) {
                severityMap.put(record.MasterLabel.toLowerCase(), record.Severity__c);
            }
        }
        return severityMap;
    }

    public static String getSeverity(String actionCode) {
        if (String.isBlank(actionCode)) return null; // default
        String mapped = getSeverityMap().get(actionCode.toLowerCase());
        return mapped != null ? mapped : null; // fallback default
    }
    
    public static MatchResult getMatch(String section, String action) {
        MatchResult result = new MatchResult();
        result.severity           = 'Medium';
        result.securityCategory   = 'None';
        result.securityWeight     = 0;
        result.isSecurityRelevant = false;
        result.decayEligible      = true;
        result.actionScore        = 50;   // neutral default
        result.scoreWeight        = 1.0;
		
        severityByAction = getSeverityMapping();
        for (Audit_Severity__mdt p : severityByAction.values()) {
            
            /*if (String.isNotBlank(p.Section__c)
                && !p.Section__c.equalsIgnoreCase(section)) {
                continue;
            }*/
            System.debug('p.Action__c:::' + p.Action__c + ' =  ' + action + ' = Action score = ' + p.Action_Score__c);
            try {
                if (p.Action__c == action) {
                    result.severity           = p.Severity__c;
                    result.securityCategory   = p.Security_Impact_Category__c;
                    result.securityWeight     = (Integer)(p.Security_Weight__c ?? 0);
                    result.isSecurityRelevant = p.Is_Security_Relevant__c;
                    result.decayEligible      = p.Decay_Eligible__c;
                    result.impactDescription  = p.Impact_Description__c; //Security_Impact_Description__c
                    result.actionScore        = (Integer)(p.Action_Score__c ?? 50);
                    result.scoreWeight        = p.Score_Weight__c ?? 1.0;
                    return result;
                }
            } catch (Exception e) {
                System.debug('Invalid regex [' + p.DeveloperName
                             + ']: ' + e.getMessage());
            }
        }
        return result;
    }

    /*private static List<Audit_Severity__mdt> getSeverityRecord() {
        return [
            SELECT DeveloperName,
            Section__c, Severity__c, Sort_Order__c,
            Security_Impact_Category__c, Security_Weight__c,
            Is_Security_Relevant__c, Decay_Eligible__c,
            Impact_Description__c, Action__c,
            Action_Score__c, Score_Weight__c
            FROM Audit_Severity__mdt
            WHERE Active__c = true
            ORDER BY Sort_Order__c ASC NULLS LAST
        ];
    }
    */
    
    private static Map<String, Audit_Severity__mdt> getSeverityMapping() {

        if (severityByAction == null) {
    
            severityByAction = new Map<String, Audit_Severity__mdt>();
    
            for (Audit_Severity__mdt rec : [
                SELECT Action__c,
                       Severity__c,
                       Security_Impact_Category__c,
                       Security_Weight__c,
                       Is_Security_Relevant__c,
                       Decay_Eligible__c,
                       Impact_Description__c,
                       Action_Score__c,
                       Score_Weight__c
                FROM Audit_Severity__mdt
                WHERE Active__c = true
            ]) {
                severityByAction.put(rec.Action__c, rec);
            }
        }
    
        return severityByAction;
    }
    public class MatchResult {
        public String  severity;
        public String  securityCategory;
        public Integer securityWeight;
        public Boolean isSecurityRelevant;
        public Boolean decayEligible;
        public String  impactDescription;
        public Integer actionScore;    // NEW — 0 to 100
        public Decimal scoreWeight;    // NEW — influence multiplier
    }
    
}