# ✈️ Air Freight Analytics & Cost Apportionment Pipeline (SQL)

### 📌 Executive Summary
This repository contains an advanced, end-to-end SQL data pipeline engineered for the Air Express Logistics vertical. Managing air freight data requires blending highly structured surface transport data (first/last-mile delivery trucks) with unstructured, highly variable airline manifest data. 

This pipeline acts as the central intelligence engine, taking raw relational data and transforming it into a flat, highly readable view that calculates total landed cost, tracks carrier SLA compliance, and apportions indirect hub expenses (petty cash) directly alongside shipment revenue.

---

### 🛠️ Core Technical Capabilities & SQL Architecture

This pipeline is built using over a dozen interconnected Common Table Expressions (CTEs) to ensure code readability and execution efficiency. 

#### 1. Multi-Modal String Aggregation (`STRING_AGG`)
Air shipments rarely use a single vehicle or flight. A single docket might be tied to multiple pickup trucks, two different airline flights, and a delivery van. 
*   **The Logic:** Using `STRING_AGG()` combined with `CROSS APPLY`, this query flattens 1-to-Many relationships. It collapses multiple flight numbers (e.g., *IndiGo 6E-123, SpiceJet SG-456*) into a single, easily reportable row per docket, preventing data duplication (fan-out) in the final BI dashboard.

#### 2. Dynamic SLA & Breach Engine
Air shipments are highly time-sensitive. This query features a dedicated SLA computation module that evaluates delivery attempt timestamps against Estimated Delivery Dates (EDDs).
*   **The Logic:** It dynamically adjusts the final EDD by querying `fct_delivery_run_sheet` to check if a delay was caused by a valid exception (e.g., "Airport Strike" or "Customer Not Available") versus a carrier fault, categorizing shipments into strict `On-Time` or `SLA Breach` buckets.

#### 3. Heterogeneous Data Merging (`UNION ALL`)
To calculate true profitability, you must look beyond direct freight costs.
*   **The Logic:** The pipeline processes hundreds of thousands of transactional shipments, but in Phase 7, it utilizes a `UNION ALL` statement to append entirely different data sets: **Indirect Hub Expenses (Petty Cash)**. By aligning the column structures via `CAST(NULL...)`, business analysts can seamlessly filter profitability by a specific "Air Hub Branch" and see both the revenue generated and the indirect cash burned in the same view.

#### 4. Cost Apportionment Mathematics
*   **The Logic:** Integrates logic to take bulk trip costs (e.g., paying a vendor ₹50,000 for a truck to the airport) and apportions that cost down to the individual packet level based on docket count and volumetric weight ratios.

---

### 💼 Business Impact
*   **Cost Leakage Prevention:** By marrying CRM claims data (Damage/Shortage/Delay) directly to the docket, finance teams can immediately flag shipments that resulted in a net loss.
*   **Carrier Scorecarding:** The automated flight mapping allows management to track exactly which commercial airlines frequently breach SLA timelines.
*   **Operational Visibility:** The `ReasonCategory` logic allows operations teams to instantly separate true operational failures from unavoidable external delays.

### 📁 Repository Structure
*   `air_freight_pipeline.sql`: The primary sanitized stored procedure.
*   *(Note: Database schemas, airline mappings, and branch identifiers have been anonymized to generic structures to adhere to data security best practices).*
