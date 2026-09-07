public class OrgSecurityScoreService {

    public class ScoreResult {
        public Decimal  orgScore;               // 0–100
        public String   band;                   // Excellent/Good/Fair/Poor/Critical
        public Integer  totalRecords;
        public Integer  compliantCount;
        public Integer  nonCompliantCount;
        public Decimal  complianceRate;         // % of compliant records
        public Map<String, Decimal> scoreBySection;   // breakdown by section
        public Map<String, Decimal> scoreByUser;      // breakdown by user
        public Datetime calculatedAt;
    }

    public static ScoreResult calculateOrgScore(Integer lookbackDays) {

        Datetime windowStart = Datetime.now().addDays(-lookbackDays);

        // Query all Change_Log__c records in the window
        List<Change_Log__c> logs = [
            SELECT Id, Section__c, Action__c, Action_Score__c,
                   Weighted_Score__c, Non_Compliant__c,
                   Log_Created_Date__c, Changed_By_User__c,
                   Changed_By_User__r.Name
            FROM Change_Log__c
            WHERE Log_Created_Date__c >= :windowStart
            ORDER BY Log_Created_Date__c ASC
        ];

        if (logs.isEmpty()) {
            ScoreResult empty = new ScoreResult();
            empty.orgScore        = 100;
            empty.band            = 'Excellent';
            empty.totalRecords    = 0;
            empty.calculatedAt    = Datetime.now();
            return empty;
        }

        Decimal totalWeightedScore = 0;
        Decimal totalWeight        = 0;
        Integer compliantCount     = 0;
        Integer nonCompliantCount  = 0;

        Map<String, Decimal> sectionScoreSum    = new Map<String, Decimal>();
        Map<String, Decimal> sectionWeightSum   = new Map<String, Decimal>();
        Map<String, Decimal> userScoreSum       = new Map<String, Decimal>();
        Map<String, Decimal> userWeightSum      = new Map<String, Decimal>();

        for (Change_Log__c log : logs) {

            Integer score   = (Integer)(log.Action_Score__c  ?? 50);
            Decimal weight  = log.Weighted_Score__c != null
                              ? (log.Weighted_Score__c / (score == 0 ? 1 : score))
                              : 1.0;

            // Time decay — recent events matter more
            // Events from today = weight × 1.0
            // Events from 30 days ago = weight × 0.5
            Integer daysOld   = log.Log_Created_Date__c.date()
                                    .daysBetween(Date.today());
            Decimal decayFactor = Math.max(0.5,
                1.0 - (Decimal.valueOf(daysOld) / (lookbackDays * 2)));

            Decimal effectiveWeight = weight * decayFactor;

            totalWeightedScore += score * effectiveWeight;
            totalWeight        += effectiveWeight;

            // Compliance counts
            if (log.Non_Compliant__c) {
                nonCompliantCount++;
            } else {
                compliantCount++;
            }

            // Section breakdown
            String sec = log.Section__c ?? 'Unknown';
            sectionScoreSum.put(sec,
                (sectionScoreSum.get(sec) ?? 0) + (score * effectiveWeight));
            sectionWeightSum.put(sec,
                (sectionWeightSum.get(sec) ?? 0) + effectiveWeight);

            // User breakdown
            String userName = log.Changed_By_User__r?.Name ?? log.Changed_By_User__c;
            userScoreSum.put(userName,
                (userScoreSum.get(userName) ?? 0) + (score * effectiveWeight));
            userWeightSum.put(userName,
                (userWeightSum.get(userName) ?? 0) + effectiveWeight);
        }

        // Final org score — weighted average
        Decimal orgScore = totalWeight > 0
                           ? (totalWeightedScore / totalWeight).setScale(1)
                           : 100;
        orgScore = Math.min(100, Math.max(0, orgScore));

        // Section scores
        Map<String, Decimal> scoreBySection = new Map<String, Decimal>();
        for (String sec : sectionScoreSum.keySet()) {
            Decimal avg = (sectionScoreSum.get(sec)
                           / sectionWeightSum.get(sec)).setScale(1);
            scoreBySection.put(sec, avg);
        }

        // User scores
        Map<String, Decimal> scoreByUser = new Map<String, Decimal>();
        for (String usr : userScoreSum.keySet()) {
            Decimal avg = (userScoreSum.get(usr)
                           / userWeightSum.get(usr)).setScale(1);
            scoreByUser.put(usr, avg);
        }

        // Build result
        ScoreResult result       = new ScoreResult();
        result.orgScore          = orgScore;
        result.band              = getBand(orgScore);
        result.totalRecords      = logs.size();
        result.compliantCount    = compliantCount;
        result.nonCompliantCount = nonCompliantCount;
        result.complianceRate    = (Decimal.valueOf(compliantCount)
                                   / logs.size() * 100).setScale(1);
        result.scoreBySection    = scoreBySection;
        result.scoreByUser       = scoreByUser;
        result.calculatedAt      = Datetime.now();
        return result;
    }

    private static String getBand(Decimal score) {
        if (score >= 90) return 'Excellent';
        if (score >= 75) return 'Good';
        if (score >= 60) return 'Fair';
        if (score >= 40) return 'Poor';
        return 'Critical';
    }
}