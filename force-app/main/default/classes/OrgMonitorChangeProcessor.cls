/**
 * Bulk processing for one SetupAuditTrail batch scope.
 * This is an intentional system-mode boundary: scheduled collection must see setup
 * events and governance records consistently, independent of record sharing. No
 * subscriber-supplied SOQL, endpoint, credential, or destination is accepted here.
 */
public without sharing class OrgMonitorChangeProcessor {
    public interface LoginDataProvider {
        Boolean loginHistoryReadable();
        List<LoginHistory> queryLoginHistories(Set<Id> actorIds, Datetime latestChangeTime);
        Boolean loginGeoReadable();
        Map<Id, LoginGeo> queryLoginGeos(Set<Id> geoIds);
    }
    private class SalesforceLoginDataProvider implements LoginDataProvider {
        public Boolean loginHistoryReadable() {
            return fieldsReadable('LoginHistory', new Set<String>{
                'Id', 'UserId', 'LoginTime', 'Status', 'SourceIp', 'ForwardedForIp', 'LoginGeoId'
            });
        }
        public List<LoginHistory> queryLoginHistories(Set<Id> actorIds, Datetime latestChangeTime) {
            return [
                SELECT Id, UserId, LoginTime, Status, SourceIp, ForwardedForIp, LoginGeoId
                FROM LoginHistory
                WHERE UserId IN :actorIds AND LoginTime <= :latestChangeTime
                ORDER BY UserId, LoginTime DESC
            ];
        }
        public Boolean loginGeoReadable() {
            return fieldsReadable('LoginGeo', new Set<String>{
                'Id', 'City', 'Subdivision', 'Country', 'PostalCode'
            });
        }
        public Map<Id, LoginGeo> queryLoginGeos(Set<Id> geoIds) {
            return new Map<Id, LoginGeo>([
                SELECT Id, City, Subdivision, Country, PostalCode FROM LoginGeo WHERE Id IN :geoIds
            ]);
        }
        private Boolean fieldsReadable(String objectName, Set<String> fieldNames) {
            Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectName);
            if (objectType == null || !objectType.getDescribe().isAccessible()) return false;
            Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
            for (String fieldName : fieldNames) {
                if (!fields.containsKey(fieldName)
                        || !fields.get(fieldName).getDescribe().isAccessible()) return false;
            }
            return true;
        }
    }
    @TestVisible private LoginDataProvider loginDataProvider = new SalesforceLoginDataProvider();
    public class Outcome {
        public Boolean successful = true;
        public Integer createdCount = 0;
        public List<String> diagnostics = new List<String>();
    }
    private class ActorResolution {
        User auditUser;
        User effectiveActor;
        User actingAsUser;
        String rawDelegate;
        String actingAsUserName;
        Boolean delegated;
    }
    private class Classification {
        OrgMonitorChangeRunConfig.Rule rule;
        String operation = 'OBSERVE';
        String metadataType = 'Unclassified';
        String category = 'Unclassified';
        String severity = 'LOW';
        String riskDescription;
        String componentName;
        Boolean excluded = false;
        Boolean redactSensitiveData = false;
    }
    private class WindowContext {
        Deployment_Window__c row;
        Set<Id> nominated = new Set<Id>();
        Datetime approvedAt;
    }
    private class WorkItem {
        SObject source;
        ActorResolution actor;
        Classification classification;
    }
    private class LoginEnrichment {
        String sourceIp, forwardedForIp, city, state, country, postalCode;
    }
    public class ComplianceDecision {
        public Boolean compliant;
        public String code;
        public String reason;
        public Id windowId;
    }

    public Outcome process(List<SObject> sourceRows, OrgMonitorChangeRunConfig config,
            String runCorrelationId) {
        Outcome outcome = new Outcome();
        if (sourceRows == null || sourceRows.isEmpty()) return outcome;

        Set<String> sourceIds = new Set<String>();
        Set<Id> auditUserIds = new Set<Id>();
        Set<String> delegateKeys = new Set<String>();
        Set<String> loginAsTargetNames = new Set<String>();
        Datetime earliest, latest;
        for (SObject row : sourceRows) {
            sourceIds.add(String.valueOf(row.get('Id')));
            Id auditUserId = (Id) row.get('CreatedById');
            if (auditUserId != null) auditUserIds.add(auditUserId);
            String delegateValue = (String) row.get('DelegateUser');
            if (String.isNotBlank(delegateValue)) delegateKeys.add(delegateValue.trim());
            if (isLoginAsAction((String)row.get('Action'))) {
                String targetName = extractLoginAsTarget((String)row.get('Display'));
                if (String.isNotBlank(targetName)) loginAsTargetNames.add(targetName);
            }
            Datetime changedAt = (Datetime) row.get('CreatedDate');
            if (changedAt != null) {
                earliest = earliest == null || changedAt < earliest ? changedAt : earliest;
                latest = latest == null || changedAt > latest ? changedAt : latest;
            }
        }

        Set<String> existingIds = new Set<String>();
        for (Change_Log__c row : [
            SELECT External_Id__c FROM Change_Log__c WHERE External_Id__c IN :sourceIds
        ]) existingIds.add(row.External_Id__c);

        Map<Id, User> auditUsers = new Map<Id, User>();
        if (!auditUserIds.isEmpty()) auditUsers = new Map<Id, User>([
            SELECT Id, Name, Username, FederationIdentifier, UserType, IsActive
            FROM User WHERE Id IN :auditUserIds
        ]);
        Map<String, User> delegates = resolveDelegates(delegateKeys);
        Map<String, User> loginAsTargets = resolveUniqueUsersByName(loginAsTargetNames);
        List<WorkItem> work = new List<WorkItem>();
        for (SObject source : sourceRows) {
            String sourceId = String.valueOf(source.get('Id'));
            if (existingIds.contains(sourceId)) continue;
            ActorResolution actor = resolveActor(source, auditUsers, delegates, loginAsTargets);
            if (actor == null || !isInternal(actor.effectiveActor)) continue;
            Classification classification = classify(source, config.rules);
            if (classification.excluded == true) continue;
            applyDelegatedSeverityFloor(classification, actor);
            WorkItem item = new WorkItem();
            item.source = source; item.actor = actor; item.classification = classification;
            work.add(item);
        }
        if (work.isEmpty()) return outcome;

        Map<String, LoginEnrichment> enrichmentBySourceId = enrichFromLoginHistory(work);
        List<WindowContext> windows = loadWindows(earliest, latest, config.approvalRequired);
        List<Change_Log__c> pending = new List<Change_Log__c>();
        for (WorkItem item : work) {
            SObject source = item.source;
            ComplianceDecision compliance = evaluateCompliance(
                (Datetime)source.get('CreatedDate'), item.actor.effectiveActor, windows, config);
            pending.add(buildRecord(source, item.actor, item.classification, compliance,
                enrichmentBySourceId.get(String.valueOf(source.get('Id'))), config,
                runCorrelationId));
        }
        if (pending.isEmpty()) return outcome;

        List<Database.SaveResult> saves = Database.insert(pending, false);
        for (Integer index = 0; index < saves.size(); index++) {
            if (saves[index].isSuccess()) {
                outcome.createdCount++;
            } else {
                outcome.successful = false;
                for (Database.Error error : saves[index].getErrors()) {
                    outcome.diagnostics.add(error.getStatusCode() + ': ' + sanitize(error.getMessage()));
                }
            }
        }
        return outcome;
    }

    private Map<String, LoginEnrichment> enrichFromLoginHistory(List<WorkItem> work) {
        Map<String, LoginEnrichment> result = new Map<String, LoginEnrichment>();
        if (work.isEmpty() || !loginDataProvider.loginHistoryReadable()) return result;
        Set<Id> actorIds = new Set<Id>();
        Datetime latestChangeTime;
        for (WorkItem item : work) {
            actorIds.add(item.actor.effectiveActor.Id);
            Datetime changedAt = (Datetime)item.source.get('CreatedDate');
            if (latestChangeTime == null || changedAt > latestChangeTime) latestChangeTime = changedAt;
        }
        Map<Id, List<LoginHistory>> historiesByActor = new Map<Id, List<LoginHistory>>();
        for (LoginHistory login : loginDataProvider.queryLoginHistories(actorIds, latestChangeTime)) {
            if (!historiesByActor.containsKey(login.UserId))
                historiesByActor.put(login.UserId, new List<LoginHistory>());
            historiesByActor.get(login.UserId).add(login);
        }
        Map<String, LoginHistory> selectedBySourceId = new Map<String, LoginHistory>();
        Set<Id> geoIds = new Set<Id>();
        for (WorkItem item : work) {
            LoginHistory selected = selectMostRecentSuccessfulLogin(
                historiesByActor.get(item.actor.effectiveActor.Id),
                (Datetime)item.source.get('CreatedDate'));
            if (selected == null) continue;
            String sourceId = String.valueOf(item.source.get('Id'));
            selectedBySourceId.put(sourceId, selected);
            if (selected.LoginGeoId != null) geoIds.add(selected.LoginGeoId);
        }
        Map<Id, LoginGeo> geos = new Map<Id, LoginGeo>();
        if (!geoIds.isEmpty() && loginDataProvider.loginGeoReadable())
            geos = loginDataProvider.queryLoginGeos(geoIds);
        for (String sourceId : selectedBySourceId.keySet()) {
            LoginHistory login = selectedBySourceId.get(sourceId);
            LoginGeo geo = geos.get(login.LoginGeoId);
            LoginEnrichment value = new LoginEnrichment();
            value.sourceIp = login.SourceIp; value.forwardedForIp = login.ForwardedForIp;
            if (geo != null) {
                value.city = geo.City; value.state = geo.Subdivision;
                value.country = geo.Country; value.postalCode = geo.PostalCode;
            }
            result.put(sourceId, value);
        }
        return result;
    }

    @TestVisible
    private static LoginHistory selectMostRecentSuccessfulLogin(
            List<LoginHistory> histories, Datetime changedAt) {
        if (histories == null || changedAt == null) return null;
        LoginHistory selected;
        for (LoginHistory login : histories) {
            if (login.Status != 'Success' || login.LoginTime == null || login.LoginTime > changedAt) continue;
            if (selected == null || login.LoginTime > selected.LoginTime) selected = login;
        }
        return selected;
    }

    private Map<String, User> resolveDelegates(Set<String> keys) {
        Map<String, User> result = new Map<String, User>();
        if (keys.isEmpty()) return result;
        Set<String> ambiguous = new Set<String>();
        for (User row : [
            SELECT Id, Name, Username, FederationIdentifier, UserType, IsActive
            FROM User WHERE Username IN :keys OR FederationIdentifier IN :keys
        ]) {
            for (String stableKey : new List<String>{ row.Username, row.FederationIdentifier }) {
                if (String.isBlank(stableKey) || !keys.contains(stableKey)) continue;
                if (result.containsKey(stableKey)) ambiguous.add(stableKey);
                else result.put(stableKey, row);
            }
        }
        for (String key : ambiguous) result.remove(key);
        return result;
    }

    private ActorResolution resolveActor(SObject source, Map<Id, User> auditUsers,
            Map<String, User> delegates, Map<String, User> loginAsTargets) {
        User auditUser = auditUsers.get((Id) source.get('CreatedById'));
        String rawDelegate = (String) source.get('DelegateUser');
        ActorResolution result = new ActorResolution();
        result.auditUser = auditUser;
        result.actingAsUser = auditUser;
        result.rawDelegate = rawDelegate;
        result.delegated = String.isNotBlank(rawDelegate);
        if (result.delegated) {
            result.effectiveActor = delegates.get(rawDelegate.trim());
            if (result.effectiveActor == null) return null;
            if (isLoginAsAction((String)source.get('Action'))) {
                result.actingAsUserName = extractLoginAsTarget((String)source.get('Display'));
                result.actingAsUser = loginAsTargets.get(result.actingAsUserName);
            } else if (auditUser != null && auditUser.Id != result.effectiveActor.Id) {
                result.actingAsUserName = auditUser.Name;
            }
        } else {
            result.effectiveActor = auditUser;
        }
        return result;
    }

    private Map<String, User> resolveUniqueUsersByName(Set<String> names) {
        Map<String, User> result = new Map<String, User>();
        Set<String> ambiguous = new Set<String>();
        if (names.isEmpty()) return result;
        for (User row : [
            SELECT Id, Name, Username, FederationIdentifier, UserType, IsActive
            FROM User WHERE Name IN :names
        ]) {
            if (result.containsKey(row.Name)) ambiguous.add(row.Name);
            else result.put(row.Name, row);
        }
        for (String name : ambiguous) result.remove(name);
        return result;
    }

    private Boolean isLoginAsAction(String action) {
        return new Set<String>{ 'SUORGADMINLOGIN', 'SUNETWORKADMINLOGIN', 'SULOGINACCESSUSED' }
            .contains(String.isBlank(action) ? '' : action.trim().toUpperCase());
    }

    private String extractLoginAsTarget(String display) {
        if (String.isBlank(display)) return null;
        Matcher matcher = Pattern.compile('(?i)^Logged in using Login-As access for\\s+(.+)$').matcher(display.trim());
        return matcher.matches() ? trimTo(matcher.group(1), 255) : null;
    }

    private Boolean isInternal(User actor) {
        if (actor == null || String.isBlank(actor.UserType)) return false;
        String userType = actor.UserType.toLowerCase();
        if (userType.contains('guest') || userType.contains('customer')
                || userType.contains('partner') || userType.contains('portal')
                || userType == 'csnonly' || userType == 'automatedprocess') return false;
        return true;
    }

    private Classification classify(SObject source, List<OrgMonitorChangeRunConfig.Rule> rules) {
        String action = (String) source.get('Action');
        String section = (String) source.get('Section');
        String display = (String) source.get('Display');
        Classification result = new Classification();
        for (OrgMonitorChangeRunConfig.Rule candidate : rules) {
            if (!matches(candidate, action, section, display)) continue;
            result.rule = candidate;
            result.operation = blankOr(candidate.operation, 'OBSERVE');
            result.metadataType = blankOr(candidate.metadataType, 'Unclassified');
            result.category = blankOr(candidate.category, 'Unclassified');
            result.severity = blankOr(candidate.severity, 'LOW');
            result.riskDescription = candidate.riskDescription;
            result.componentName = extractComponent(candidate, display);
            result.excluded = candidate.ignore == true;
            result.redactSensitiveData = candidate.redactSensitiveData == true;
            if (result.redactSensitiveData == true) result.componentName = null;
            if (candidate.ignoreWhenNoChange == true && indicatesNoChange(display)) result.excluded = true;
            return result;
        }
        return result;
    }

    private Boolean indicatesNoChange(String display) {
        if (String.isBlank(display)) return false;
        return Pattern.matches('(?i).*\\b(no changes?|unchanged)\\b.*', display);
    }

    private Boolean matches(OrgMonitorChangeRunConfig.Rule rule, String action,
            String section, String display) {
        if (rule.matchType == 'EXACT_ACTION_SECTION') {
            return equalsIgnoreCase(action, rule.action) && equalsIgnoreCase(section, rule.section);
        }
        if (rule.matchType == 'EXACT_ACTION') return equalsIgnoreCase(action, rule.action);
        if (rule.matchType == 'DISPLAY_PATTERN') {
            try {
                return regexFind(rule.actionRegex, action) && regexFind(rule.sectionRegex, section)
                    && regexFind(rule.displayRegex, display);
            }
            catch (Exception ignored) { return false; }
        }
        if (rule.matchType == 'SECTION_FALLBACK') {
            return (String.isBlank(section) && String.isBlank(rule.section))
                || equalsIgnoreCase(section, rule.section);
        }
        return rule.matchType == 'GLOBAL_FALLBACK';
    }

    private void applyDelegatedSeverityFloor(Classification classification, ActorResolution actor) {
        if (actor.delegated != true) return;
        classification.severity = 'CRITICAL';
        String delegatedRisk = 'Login-As activity increases impersonation and accountability risk.';
        classification.riskDescription = String.isBlank(classification.riskDescription)
            ? delegatedRisk : classification.riskDescription.trim() + ' ' + delegatedRisk;
    }

    private Boolean regexFind(String expression, String value) {
        return String.isBlank(expression) || (value != null
            && Pattern.compile(expression).matcher(value).find());
    }

    private String extractComponent(OrgMonitorChangeRunConfig.Rule rule, String display) {
        if (String.isBlank(rule.targetRegex) || String.isBlank(display) || rule.componentGroup <= 0) return null;
        try {
            Matcher matcher = Pattern.compile(rule.targetRegex).matcher(display);
            if (!matcher.find() || rule.componentGroup > matcher.groupCount()) return null;
            return trimTo(matcher.group(rule.componentGroup), 255);
        } catch (Exception ignored) { return null; }
    }

    private List<WindowContext> loadWindows(Datetime earliest, Datetime latest,
            Boolean approvalRequired) {
        List<WindowContext> result = new List<WindowContext>();
        if (earliest == null || latest == null) return result;
        Map<Id, WindowContext> byId = new Map<Id, WindowContext>();
        Set<String> qualifyingStatuses = new Set<String>{ 'Active', 'Closed', 'Completed', 'Expired' };
        for (Deployment_Window__c row : [
            SELECT Id, Name, Start_Date_Time__c, End_Date_Time__c, Status__c,
                   Enable_Approval_Process__c,
                   (SELECT User__c FROM Authorised_Deployment_Users__r)
            FROM Deployment_Window__c
            WHERE Start_Date_Time__c <= :latest
              AND (End_Date_Time__c > :earliest OR End_Date_Time__c = null)
            ORDER BY Start_Date_Time__c DESC, End_Date_Time__c ASC NULLS LAST, Id ASC
        ]) {
            if (!qualifyingStatuses.contains(row.Status__c)) continue;
            WindowContext context = new WindowContext();
            context.row = row;
            for (Authorised_Deployment_User__c nominated : row.Authorised_Deployment_Users__r) {
                if (nominated.User__c != null) context.nominated.add(nominated.User__c);
            }
            result.add(context);
            byId.put(row.Id, context);
        }
        if (approvalRequired && !byId.isEmpty()) {
            for (ProcessInstanceStep step : [
                SELECT ProcessInstance.TargetObjectId, CreatedDate
                FROM ProcessInstanceStep
                WHERE ProcessInstance.TargetObjectId IN :byId.keySet()
                  AND StepStatus = 'Approved'
                ORDER BY CreatedDate DESC
            ]) {
                WindowContext context = byId.get(step.ProcessInstance.TargetObjectId);
                if (context != null && context.approvedAt == null) context.approvedAt = step.CreatedDate;
            }
        }
        return result;
    }

    private ComplianceDecision evaluateCompliance(Datetime changedAt, User actor,
            List<WindowContext> windows, OrgMonitorChangeRunConfig config) {
        if (config.sandboxWindowSkip && config.appSetupDeploymentUserIds.contains(actor.Id)) {
            return decision(true, 'SANDBOX_WINDOW_SKIP', null,
                'Compliant — Sandbox deployment-window checks were skipped for nominated deployment user '
                + actor.Name + ' under the “Skip Deployment Windows for Sandbox” setting.');
        }
        List<WindowContext> covering = new List<WindowContext>();
        for (WindowContext window : windows) {
            if (window.row.Start_Date_Time__c != null && changedAt >= window.row.Start_Date_Time__c
                    && (window.row.End_Date_Time__c == null || changedAt < window.row.End_Date_Time__c)) {
                covering.add(window);
            }
        }
        if (covering.isEmpty()) {
            return decision(false, 'NO_DEPLOYMENT_WINDOW', null,
                'Non-compliant — No deployment window covered the change time of '
                + new OrgMonitorDateTimeFormatter(config.orgTimeZoneSidKey).formatDateTime(changedAt) + '.');
        }
        WindowContext invalid, unapproved, notNominated;
        for (WindowContext window : covering) {
            Boolean valid = window.row.Start_Date_Time__c != null
                && window.row.End_Date_Time__c != null
                && window.row.End_Date_Time__c > window.row.Start_Date_Time__c;
            if (!valid) { if (invalid == null) invalid = window; continue; }
            Boolean approved = !config.approvalRequired
                || (window.approvedAt != null && window.approvedAt <= changedAt);
            if (!approved) { if (unapproved == null) unapproved = window; continue; }
            if (!window.nominated.contains(actor.Id)) {
                if (notNominated == null) notNominated = window;
                continue;
            }
            if (config.approvalRequired) {
                return decision(true, 'APPROVED_WINDOW_NOMINATED_USER', window.row.Id,
                    'Compliant — Change occurred during approved deployment window ' + window.row.Name
                    + ' and was performed by nominated deployment user ' + actor.Name + '.');
            }
            return decision(true, 'WINDOW_APPROVAL_NOT_REQUIRED', window.row.Id,
                'Compliant — Change occurred during deployment window ' + window.row.Name
                + '. Deployment-window approval was not required by the Org Monitor setting, and '
                + actor.Name + ' was a nominated deployment user.');
        }
        if (invalid != null) return decision(false, 'INVALID_WINDOW_CONFIGURATION', invalid.row.Id,
            'Non-compliant — Deployment window ' + invalid.row.Name
            + ' covered the change time, but its configuration was invalid or incomplete.');
        if (unapproved != null) return decision(false, 'WINDOW_NOT_APPROVED', unapproved.row.Id,
            'Non-compliant — Change occurred during deployment window ' + unapproved.row.Name
            + ', but the window had not been approved before the change was made.');
        return decision(false, 'USER_NOT_NOMINATED', notNominated == null ? null : notNominated.row.Id,
            'Non-compliant — Change occurred during approved deployment window '
            + (notNominated == null ? '' : notNominated.row.Name)
            + ', but ' + actor.Name + ' was not a nominated deployment user for that window.');
    }

    private ComplianceDecision decision(Boolean compliant, String code, Id windowId, String reason) {
        ComplianceDecision result = new ComplianceDecision();
        result.compliant = compliant; result.code = code;
        result.windowId = windowId; result.reason = reason;
        return result;
    }

    private Change_Log__c buildRecord(SObject source, ActorResolution actor,
            Classification classification, ComplianceDecision compliance,
            LoginEnrichment enrichment, OrgMonitorChangeRunConfig config, String correlationId) {
        Change_Log__c target = new Change_Log__c();
        target.External_Id__c = String.valueOf(source.get('Id'));
        target.Log_Created_Date__c = (Datetime) source.get('CreatedDate');
        target.Unusual_Hours__c = isUnusualAt((Datetime)source.get('CreatedDate'),
            config.orgTimeZoneSidKey, config.unusualHoursStart, config.unusualHoursEnd);
        target.Changed_By_User__c = actor.actingAsUser == null ? null : actor.actingAsUser.Id;
        target.Delegate_Username__c = trimTo(actor.rawDelegate, 255);
        target.Is_Delegated_Access__c = actor.delegated;
        target.Effective_Actor__c = actor.effectiveActor.Id;
        target.Action__c = trimTo((String) source.get('Action'), 255);
        target.Section__c = trimTo((String) source.get('Section'), 255);
        target.Details__c = classification.redactSensitiveData
            ? '[REDACTED BY CLASSIFICATION RULE]' : trimTo((String) source.get('Display'), 255);
        target.Change_Operation__c = trimTo(classification.operation, 50);
        target.Component_Name__c = trimTo(classification.componentName, 255);
        target.Metadata_Type__c = trimTo(classification.metadataType, 255);
        target.Category__c = trimTo(classification.category, 80);
        target.Severity__c = classification.severity;
        target.Risk_Description__c = classification.riskDescription;
        if (classification.rule != null) {
            target.Action_Score__c = classification.rule.actionScore;
            target.Score_Weight__c = classification.rule.scoreWeight;
            if (classification.rule.actionScore != null && classification.rule.scoreWeight != null) {
                target.Weighted_Score__c = classification.rule.actionScore * classification.rule.scoreWeight;
            }
        }
        target.Classification_Rule_Key__c = classification.rule == null ? null : classification.rule.key;
        target.Matched_Deployment_Window__c = compliance.windowId;
        target.Non_Compliant__c = !compliance.compliant;
        target.Compliance_Reason_Code__c = compliance.code;
        target.Compliance_Reason__c = compliance.reason;
        target.Non_Compliant_Reason__c = trimTo(compliance.reason, 255);
        target.Run_Correlation_Id__c = correlationId;
        if (enrichment != null) {
            target.Source_IP__c = trimTo(enrichment.sourceIp, 255);
            target.Forwarded_For_IP__c = trimTo(enrichment.forwardedForIp, 255);
            target.User_Location_City__c = trimTo(enrichment.city, 255);
            target.User_Location_State__c = trimTo(enrichment.state, 255);
            target.User_Location_Country__c = trimTo(enrichment.country, 255);
            target.User_Location_Postal_Code__c = trimTo(enrichment.postalCode, 255);
        }
        target.Change_Summary__c = buildSummary(
            (String)source.get('Display'), actor, classification, compliance.reason);
        target.Raw_Audit_Entry__c = classification.redactSensitiveData
            ? redactedEvidence(source) : JSON.serialize(source);
        return target;
    }

    @TestVisible
    private static Boolean isUnusualAt(Datetime sourceTime, String timeZoneSidKey,
            Time unusualStart, Time unusualEnd) {
        if (sourceTime == null || String.isBlank(timeZoneSidKey)) return false;
        return isUnusualTime(toOrganizationTime(sourceTime,
            TimeZone.getTimeZone(timeZoneSidKey)), unusualStart, unusualEnd);
    }

    @TestVisible
    private static Time toOrganizationTime(Datetime sourceTime, TimeZone organizationTimeZone) {
        if (sourceTime == null || organizationTimeZone == null) return null;
        Datetime shifted = sourceTime.addSeconds(organizationTimeZone.getOffset(sourceTime) / 1000);
        return Time.newInstance(shifted.hourGmt(), shifted.minuteGmt(), shifted.secondGmt(), 0);
    }

    @TestVisible
    private static Boolean isUnusualTime(Time localTime, Time unusualStart, Time unusualEnd) {
        if (localTime == null || unusualStart == null || unusualEnd == null
                || unusualStart == unusualEnd) return false;
        if (unusualStart < unusualEnd)
            return localTime >= unusualStart && localTime < unusualEnd;
        return localTime >= unusualStart || localTime < unusualEnd;
    }

    private String redactedEvidence(SObject source) {
        return JSON.serialize(new Map<String, Object>{
            'Id' => source.get('Id'), 'CreatedDate' => source.get('CreatedDate'),
            'CreatedById' => source.get('CreatedById'), 'Action' => source.get('Action'),
            'Section' => source.get('Section'), 'DelegateUser' => source.get('DelegateUser'),
            'Display' => '[REDACTED BY CLASSIFICATION RULE]'
        });
    }

    private String buildSummary(String originalDisplay, ActorResolution actor,
            Classification classification, String reason) {
        if (classification.operation == 'Logged In As') {
            String targetName = String.isBlank(actor.actingAsUserName)
                ? classification.componentName : actor.actingAsUserName;
            return actor.effectiveActor.Name + ' logged in as '
                + (String.isBlank(targetName) ? 'another user' : targetName)
                + ' using administrative Login-As access. Critical security activity. '
                + canonicalReason(reason);
        }
        Boolean structured = String.isNotBlank(classification.operation)
            && classification.operation != 'OBSERVE'
            && String.isNotBlank(classification.metadataType)
            && classification.metadataType != 'Unclassified'
            && String.isNotBlank(classification.componentName);
        String description = structured
            ? OrgMonitorChangeDigestBuilder.operation(classification.operation) + ' '
                + classification.metadataType + ' “' + classification.componentName + '”'
            : displayFallback(originalDisplay);
        String actorText = 'Performed by ' + actor.effectiveActor.Name;
        if (actor.delegated && String.isNotBlank(actor.actingAsUserName)) {
            actorText += ' while logged in as ' + actor.actingAsUserName;
        }
        return description + '. ' + actorText + '. ' + canonicalReason(reason);
    }

    private String displayFallback(String originalDisplay) {
        if (String.isBlank(originalDisplay)) return 'Setup change recorded';
        String value = originalDisplay.replaceAll('[\\r\\n\\t]+', ' ').trim();
        while (value.endsWith('.')) value = value.left(value.length() - 1).trim();
        return String.isBlank(value) ? 'Setup change recorded' : value;
    }

    private String canonicalReason(String reason) {
        return String.isBlank(reason) ? 'Compliance outcome was not available.' : reason.trim();
    }

    private Boolean equalsIgnoreCase(String left, String right) {
        return left != null && right != null && left.trim().equalsIgnoreCase(right.trim());
    }
    private String blankOr(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }
    private String trimTo(String value, Integer size) {
        return value == null ? null : value.left(Math.min(value.length(), size));
    }
    private String sanitize(String value) {
        if (String.isBlank(value)) return 'Persistence failed.';
        return value.replaceAll('[\r\n\t]+', ' ').left(Math.min(value.length(), 500));
    }
}