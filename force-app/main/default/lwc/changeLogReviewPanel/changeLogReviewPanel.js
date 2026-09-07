import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import applyAction from '@salesforce/apex/ChangeLogReviewController.applyAction';
import canReview from '@salesforce/customPermission/Review_Change_Logs';
import NON_COMPLIANT from '@salesforce/schema/Change_Log__c.Non_Compliant__c';
import SEVERITY from '@salesforce/schema/Change_Log__c.Severity__c';
import STATUS from '@salesforce/schema/Change_Log__c.Lifecycle_Status__c';
import OUTCOME from '@salesforce/schema/Change_Log__c.Review_Outcome__c';

const FIELDS = [NON_COMPLIANT, SEVERITY, STATUS, OUTCOME];
export default class ChangeLogReviewPanel extends LightningElement {
    @api recordId;
    record;
    busy = false;
    @wire(getRecord, { recordId: '$recordId', fields: FIELDS }) wiredRecord({ data }) { if (data) this.record = data; }
    get nonCompliant() { return getFieldValue(this.record, NON_COMPLIANT) === true; }
    get severity() { return getFieldValue(this.record, SEVERITY); }
    get status() { return getFieldValue(this.record, STATUS); }
    get outcome() { return getFieldValue(this.record, OUTCOME); }
    get isReview() { return this.nonCompliant && this.status === 'Review'; }
    get isClosedNonCompliant() { return this.nonCompliant && this.status === 'Closed'; }
    get mayCloseWithoutReview() { return this.isReview && ['MEDIUM', 'LOW'].includes(this.severity); }
    get showActions() { return canReview && (this.isReview || this.isClosedNonCompliant); }
    get message() {
        if (this.status === 'Closed') return this.nonCompliant ? `Review outcome: ${this.outcome || 'Pending'}` : 'No review required';
        if (!this.nonCompliant) return 'No review required';
        return ['CRITICAL', 'HIGH'].includes(this.severity) ? 'Review required' : 'Review recommended';
    }
    async act(event) {
        const action = event.target.dataset.action;
        const labels = { AUTHORISE: 'Authorise and Close', UNAUTHORISE: 'Mark Unauthorised and Close', CLOSE_WITHOUT_REVIEW: 'Close Without Review', REOPEN: 'Reopen Review' };
        const confirmed = await LightningConfirm.open({ label: labels[action], message: `Confirm ${labels[action]} for this Change Log.`, variant: 'header' });
        if (!confirmed) return;
        this.busy = true;
        try {
            const result = await applyAction({ recordIds: [this.recordId], actionName: action });
            if (result.failureCount) throw new Error(result.errors.join(' '));
            this.dispatchEvent(new ShowToastEvent({ title: labels[action], message: 'Change Log updated.', variant: 'success' }));
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            this.dispatchEvent(new RefreshEvent());
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Review action failed', message: error.body?.message || error.message, variant: 'error', mode: 'sticky' }));
        } finally { this.busy = false; }
    }
}