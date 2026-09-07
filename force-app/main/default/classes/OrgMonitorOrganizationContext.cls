/**
 * Namespace-safe, transaction-cached access to trusted organisation context.
 * Tests inject a controlled subclass through GovernanceSetupController; runtime
 * behavior always reads Organization.IsSandbox.
 */
public with sharing virtual class OrgMonitorOrganizationContext {
    private Boolean sandboxValue;

    public virtual Boolean isSandbox() {
        if (sandboxValue == null) {
            sandboxValue = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        }
        return sandboxValue;
    }
}