import { LightningElement, api } from 'lwc';

export default class WizardHelpPanel extends LightningElement {
    @api title = 'What this helps us do';
    @api items = [];
}