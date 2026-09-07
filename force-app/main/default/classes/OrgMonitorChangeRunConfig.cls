/** Immutable, validated configuration snapshot for one change-detection run. */
public inherited sharing class OrgMonitorChangeRunConfig {
    public Datetime runCutoff { get; private set; }
    public Datetime lowerBoundary { get; private set; }
    public Datetime previousWatermark { get; private set; }
    public Integer historicalDays { get; private set; }
    public Boolean approvalRequired { get; private set; }
    public Boolean sandboxWindowSkip { get; private set; }
    public Boolean sandboxOrg { get; private set; }
    public String orgTimeZoneSidKey { get; private set; }
    public Time unusualHoursStart { get; private set; }
    public Time unusualHoursEnd { get; private set; }
    public Set<Id> appSetupDeploymentUserIds { get; private set; }
    public List<Rule> rules { get; private set; }

    public class Rule {
        public String key, matchType, action, section, operation, metadataType, category;
        public String severity, riskDescription, targetRegex, actionRegex, sectionRegex, displayRegex;
        public Decimal actionScore, scoreWeight;
        public Integer componentGroup, priority;
        public Boolean ignore, ignoreWhenNoChange, redactSensitiveData;
    }

    public static OrgMonitorChangeRunConfig load(Datetime cutoff) {
        if (cutoff == null) throw new ConfigurationException('Run cutoff is required.');
        ChangeLogRuntime__c settings = ChangeLogRuntime__c.getOrgDefaults();
        if (settings == null) throw new ConfigurationException('Org Monitor App Setup configuration is missing.');
        if (settings.Initial_Run_Window__c == null) {
            throw new ConfigurationException('Historical Run Timeframe is required.');
        }
        Integer days = settings.Initial_Run_Window__c.intValue();
        if (!new Set<Integer>{ 15, 30, 45 }.contains(days)) {
            throw new ConfigurationException('Historical Run Timeframe must be 15, 30, or 45 rolling days.');
        }
        validateNotificationSettings(settings);
        Time unusualStart = parseConfiguredTime(settings.Unusual_Hours_Start__c, 'Unusual Hours Start');
        Time unusualEnd = parseConfiguredTime(settings.Unusual_Hours_End__c, 'Unusual Hours End');
        validateUnusualHours(unusualStart, unusualEnd);

        OrgMonitorChangeRunConfig result = new OrgMonitorChangeRunConfig();
        result.runCutoff = cutoff;
        result.previousWatermark = settings.Last_Run_Timestamp__c;
        result.historicalDays = days;
        result.lowerBoundary = result.previousWatermark == null
            ? cutoff.addDays(-days) : result.previousWatermark;
        result.approvalRequired = settings.Enable_Deployment_Window_Approval__c == true;
        Organization orgInfo = [SELECT IsSandbox, TimeZoneSidKey FROM Organization LIMIT 1];
        result.sandboxOrg = orgInfo.IsSandbox;
        result.orgTimeZoneSidKey = orgInfo.TimeZoneSidKey;
        result.unusualHoursStart = unusualStart;
        result.unusualHoursEnd = unusualEnd;
        new OrgMonitorDateTimeFormatter(result.orgTimeZoneSidKey);
        result.sandboxWindowSkip = result.sandboxOrg
            && settings.Skip_Deployment_Windows_For_Sandbox__c == true;
        result.appSetupDeploymentUserIds = parseUserIds(settings.Deployment_User_Id__c);
        result.rules = loadAndValidateRules();
        return result;
    }

    private static List<Rule> loadAndValidateRules() {
        List<Rule> result = new List<Rule>();
        Set<String> conflicts = new Set<String>();
        Set<String> allowedTypes = new Set<String>{
            'EXACT_ACTION_SECTION', 'EXACT_ACTION', 'DISPLAY_PATTERN',
            'SECTION_FALLBACK', 'GLOBAL_FALLBACK'
        };
        Set<String> severities = new Set<String>{ 'INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL' };
        Set<String> categories = new Set<String>{
            'Automation & Business Logic', 'Code & Components', 'Data Management & Quality',
            'Data Model', 'Data Protection & Privacy', 'Email & Communication',
            'Integration & Authentication', 'Monitoring & Governance',
            'Organisation Configuration', 'Release & Package Management',
            'Security & Access', 'User Interface & Experience'
        };
        Set<String> operations = new Set<String>{
            'ACCESS_EVENT', 'ACTIVATE_OR_ENABLE', 'COMPLETE', 'CREATE_OR_ADD',
            'DEACTIVATE_OR_DISABLE', 'DELETE_OR_REMOVE', 'ERROR', 'INSTALL',
            'OBSERVE', 'PERMANENT_DELETE', 'START', 'UPDATE', 'UPGRADE', 'Logged In As'
        };
        for (Change_Action_Rule__mdt source : [
            SELECT DeveloperName, Match_Type__c, Action__c, Section__c, Active__c,
                   Change_Operation__c, Metadata_Type__c, Primary_Area__c,
                   Severity__c, Impact_Description__c, Ignore__c,
                   Ignore_When_No_Change__c, Redact_Sensitive_Data__c,
                   Target_Regex__c, Component_Name_Group__c, Priority__c
            FROM Change_Action_Rule__mdt WHERE Active__c = true
        ]) {
            Rule rule = new Rule();
            rule.key = source.DeveloperName;
            rule.matchType = normalize(source.Match_Type__c);
            rule.action = source.Action__c;
            rule.section = source.Section__c;
            rule.operation = source.Change_Operation__c;
            rule.metadataType = source.Metadata_Type__c;
            rule.category = source.Primary_Area__c;
            rule.severity = normalize(source.Severity__c);
            rule.riskDescription = source.Impact_Description__c;
            rule.ignore = source.Ignore__c == true;
            rule.ignoreWhenNoChange = source.Ignore_When_No_Change__c == true;
            rule.redactSensitiveData = source.Redact_Sensitive_Data__c == true;
            rule.targetRegex = source.Target_Regex__c;
            rule.componentGroup = source.Component_Name_Group__c == null
                ? 0 : source.Component_Name_Group__c.intValue();
            if (source.Priority__c == null) throw invalid(rule, 'Priority is required');
            rule.priority = source.Priority__c.intValue();
            if (!allowedTypes.contains(rule.matchType)) throw invalid(rule, 'Unsupported Match Type');
            if (!severities.contains(rule.severity)) throw invalid(rule, 'Unsupported severity');
            if (!categories.contains(rule.category)) throw invalid(rule, 'Unsupported category');
            if (!operations.contains(rule.operation)) throw invalid(rule, 'Unsupported change operation');
            validateCriteria(rule);
            validateExtraction(rule);
            String conflictKey = rule.matchType + '|' + normalize(rule.action) + '|'
                + normalize(rule.section) + '|' + rule.priority;
            if (!conflicts.add(conflictKey)) {
                throw invalid(rule, 'Conflicting active rule with identical criteria and priority');
            }
            result.add(rule);
        }
        for (Change_Content_Rule__mdt source : [
            SELECT DeveloperName, Priority__c, Action_Regex__c, Section_Regex__c,
                   Display_Regex__c, Primary_Area_Override__c, Severity_Override__c,
                   Metadata_Type_Override__c, Change_Operation_Override__c,
                   Impact_Description__c, Ignore__c, Redact_Sensitive_Data__c
            FROM Change_Content_Rule__mdt WHERE Active__c = true
        ]) {
            Rule rule = new Rule();
            rule.key = 'CONTENT:' + source.DeveloperName;
            rule.matchType = 'DISPLAY_PATTERN';
            rule.actionRegex = source.Action_Regex__c;
            rule.sectionRegex = source.Section_Regex__c;
            rule.displayRegex = source.Display_Regex__c;
            rule.operation = source.Change_Operation_Override__c;
            rule.metadataType = source.Metadata_Type_Override__c;
            rule.category = source.Primary_Area_Override__c;
            rule.severity = normalize(source.Severity_Override__c);
            rule.riskDescription = source.Impact_Description__c;
            rule.ignore = source.Ignore__c == true;
            rule.redactSensitiveData = source.Redact_Sensitive_Data__c == true;
            if (source.Priority__c == null) throw invalid(rule, 'Priority is required');
            rule.priority = source.Priority__c.intValue();
            validateContentRule(rule, severities, categories, operations);
            String conflictKey = rule.matchType + '|' + rule.actionRegex + '|'
                + rule.sectionRegex + '|' + rule.displayRegex + '|' + rule.priority;
            if (!conflicts.add(conflictKey)) throw invalid(rule,
                'Conflicting active content rule with identical criteria and priority');
            result.add(rule);
        }
        if (result.isEmpty()) throw new ConfigurationException('No active Change Action rules were found.');
        applyExistingScores(result);
        result.sort(new RuleOrder());
        return result;
    }

    private static void applyExistingScores(List<Rule> rules) {
        for (Audit_Severity__mdt score : [
            SELECT Action__c, Section__c, Action_Score__c, Score_Weight__c
            FROM Audit_Severity__mdt WHERE Active__c = true
        ]) {
            for (Rule rule : rules) {
                if (normalize(rule.action) != normalize(score.Action__c)) continue;
                if (String.isNotBlank(score.Section__c)
                        && normalize(rule.section) != normalize(score.Section__c)) continue;
                rule.actionScore = score.Action_Score__c;
                rule.scoreWeight = score.Score_Weight__c;
            }
        }
    }

    private static void validateCriteria(Rule rule) {
        if ((rule.matchType == 'EXACT_ACTION_SECTION' || rule.matchType == 'EXACT_ACTION')
                && (String.isBlank(rule.action) || rule.action == '*')) {
            throw invalid(rule, 'An exact rule requires Action');
        }
        // A blank-section fallback is an intentional catalogue rule for events
        // whose SetupAuditTrail.Section is itself blank.
        if (rule.matchType == 'EXACT_ACTION_SECTION' && String.isBlank(rule.section)) {
            // The completed catalogue uses this representation for exact-action fallback.
            rule.matchType = 'EXACT_ACTION';
        }
    }

    private static void validateContentRule(Rule rule, Set<String> severities,
            Set<String> categories, Set<String> operations) {
        if (String.isBlank(rule.displayRegex)) throw invalid(rule, 'Display Regex is required');
        for (String expression : new List<String>{ rule.actionRegex, rule.sectionRegex, rule.displayRegex }) {
            if (String.isBlank(expression)) continue;
            try { Pattern.compile(expression); }
            catch (Exception error) { throw invalid(rule, 'Invalid content regex'); }
        }
        if (String.isNotBlank(rule.severity) && !severities.contains(rule.severity))
            throw invalid(rule, 'Unsupported severity');
        if (String.isNotBlank(rule.category) && !categories.contains(rule.category))
            throw invalid(rule, 'Unsupported category');
        if (String.isNotBlank(rule.operation) && !operations.contains(rule.operation))
            throw invalid(rule, 'Unsupported change operation');
    }

    private static void validateExtraction(Rule rule) {
        if (String.isBlank(rule.targetRegex)) {
            if (rule.componentGroup > 0) throw invalid(rule, 'Component group requires Target Regex');
            return;
        }
        try {
            Integer groupCount = Pattern.compile(rule.targetRegex).matcher('').groupCount();
            if (rule.componentGroup > groupCount) throw invalid(rule, 'Component group exceeds regex groups');
        } catch (Exception error) {
            if (error instanceof ConfigurationException) throw error;
            throw invalid(rule, 'Invalid Target Regex');
        }
        if (rule.componentGroup < 0) throw invalid(rule, 'Component group cannot be negative');
    }

    @TestVisible
    private static OrgMonitorChangeRunConfig forTest(Datetime cutoff, Datetime watermark,
            Integer days, Boolean approval, Boolean sandbox, Boolean skip,
            Set<Id> appUsers, List<Rule> suppliedRules) {
        OrgMonitorChangeRunConfig result = new OrgMonitorChangeRunConfig();
        result.runCutoff = cutoff;
        result.previousWatermark = watermark;
        result.historicalDays = days;
        result.lowerBoundary = watermark == null ? cutoff.addDays(-days) : watermark;
        result.approvalRequired = approval;
        result.sandboxOrg = sandbox;
        result.orgTimeZoneSidKey = 'Australia/Sydney';
        result.unusualHoursStart = Time.newInstance(22, 0, 0, 0);
        result.unusualHoursEnd = Time.newInstance(6, 0, 0, 0);
        result.sandboxWindowSkip = sandbox && skip;
        result.appSetupDeploymentUserIds = appUsers == null ? new Set<Id>() : appUsers;
        result.rules = suppliedRules == null ? new List<Rule>() : suppliedRules;
        result.rules.sort(new RuleOrder());
        return result;
    }

    private static void validateNotificationSettings(ChangeLogRuntime__c settings) {
        if (settings.Slack_Notifications_Enabled__c == true
                && (settings.Slack_Last_Test__c == null || String.isBlank(settings.Slack_Channel_Id__c))) {
            throw new ConfigurationException('Slack is enabled but its tested destination is incomplete.');
        }
        if (settings.Teams_Notifications_Enabled__c == true
                && (settings.Teams_Last_Test__c == null || String.isBlank(settings.Teams_Team_Id__c)
                    || String.isBlank(settings.Teams_Channel_Id__c))) {
            throw new ConfigurationException('Microsoft Teams is enabled but its tested destination is incomplete.');
        }
    }

    private static void validateUnusualHours(Time unusualStart, Time unusualEnd) {
        if (unusualStart == null || unusualEnd == null) {
            throw new ConfigurationException('Unusual Hours Start and End are required.');
        }
        if (unusualStart == unusualEnd) {
            throw new ConfigurationException('Unusual Hours Start and End must be different.');
        }
    }
    private static Time parseConfiguredTime(String value, String label) {
        if (String.isBlank(value) || !Pattern.matches('^([01]\\d|2[0-3]):[0-5]\\d$', value.trim()))
            throw new ConfigurationException(label + ' must use 24-hour HH:mm format.');
        List<String> parts = value.trim().split(':');
        return Time.newInstance(Integer.valueOf(parts[0]), Integer.valueOf(parts[1]), 0, 0);
    }

    private static Set<Id> parseUserIds(String value) {
        Set<Id> result = new Set<Id>();
        if (String.isBlank(value)) return result;
        for (String token : value.split(',')) {
            try {
                Id candidate = (Id) token.trim();
                if (candidate.getSObjectType() == User.SObjectType) result.add(candidate);
            } catch (Exception ignored) { }
        }
        return result;
    }

    private static String normalize(String value) {
        return String.isBlank(value) ? '' : value.trim().toUpperCase();
    }
    private static ConfigurationException invalid(Rule rule, String message) {
        return new ConfigurationException(message + ': ' + rule.key);
    }
    private class RuleOrder implements Comparator<Rule> {
        public Integer compare(Rule left, Rule right) {
            Integer specificity = rank(left.matchType) - rank(right.matchType);
            if (specificity != 0) return specificity;
            if (left.priority != right.priority) return right.priority - left.priority;
            return left.key.compareTo(right.key);
        }
        private Integer rank(String value) {
            if (value == 'EXACT_ACTION_SECTION') return 1;
            if (value == 'EXACT_ACTION') return 2;
            if (value == 'DISPLAY_PATTERN') return 3;
            if (value == 'SECTION_FALLBACK') return 4;
            return 5;
        }
    }
    public class ConfigurationException extends Exception { }
}