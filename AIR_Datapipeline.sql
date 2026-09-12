USE [Logistics_Analytics_DB]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/* =========================================================================================
   Author:        [Your Name]
   Create date:   [Current Year]
   Description:   End-to-end Air Freight & Express Analytics Pipeline. 
                  Blends multi-leg surface transport (Pickup/Delivery) with airline manifests.
                  Calculates total landed cost, SLA compliance, and indirect petty cash expenses.
   ========================================================================================= */

CREATE PROCEDURE [analytics].[sp_air_express_pipeline]
    @StartDate DATETIME = NULL,
    @EndDate DATETIME = NULL,
    @CustomerID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  
    SET LOCK_TIMEOUT 30000;  
  
WITH  
/* =========================================================================================
   PHASE 1: MASTER DATA & GEOGRAPHY LOOKUPS
   ========================================================================================= */  
Air_Pincode_Final AS (  
    SELECT  
        LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20)))) AS Pincode,  
        MAX(State)               AS State,  
        MAX(CityName)            AS CityName,  
        MAX(AirZoneId)           AS AirZoneId,  
        MAX(AirZone)             AS AirZone,  
        MAX(AirPickupBranchId)   AS AirPickupBranchId,  
        MAX(AirDeliveryBranchId) AS AirDeliveryBranchId,  
        MAX(AirportID)           AS AirportID,  
        MAX(AirODAId)            AS AirODAId,  
        MAX(AirServicibility)    AS AirServicibility  
    FROM dim_pincode WITH (NOLOCK)  
    GROUP BY LTRIM(RTRIM(CAST(Pincode AS VARCHAR(20))))  
),  
  
Airport_Final AS (  
    SELECT AirportID, AirportCode, AirportName, AirportFullName, BranchId AS AirportBranchId  
    FROM dim_airport WITH (NOLOCK)  
    WHERE IsActive = 1  
),  
  
Customer_Final AS (  
    SELECT CustomerID, MAX(CustomerName) AS CustomerName, MAX(BranchID) AS CustomerBranchID  
    FROM dim_customer WITH (NOLOCK)  
    GROUP BY CustomerID  
),  
  
VendorType_Final AS (  
    SELECT Id AS VendorTypeId, Name AS VendorType, IsActive, VendorCategoryId  
    FROM dim_vendor_type WITH (NOLOCK)  
),  
  
/* =========================================================================================
   PHASE 2: EXCEPTIONS, CLAIMS, & ATTEMPTS
   ========================================================================================= */  
DRS_Latest AS (  
    SELECT DocketNo, DeliveryStatus, UndlyReasonId, AttemptDate, AttemptTime, Delivered
    FROM (
        SELECT DocketNo, DeliveryStatus, UndlyReasonId, DeliveryDate AS AttemptDate, DeliveryTime AS AttemptTime, Delivered,
               ROW_NUMBER() OVER (PARTITION BY DocketNo ORDER BY DeliveryDate DESC, DeliveryTime DESC, DetailId DESC) AS rn
        FROM fct_delivery_run_sheet WITH (NOLOCK)
    ) x WHERE rn = 1  
),  
  
CRM_Claims_Agg AS (  
    SELECT  
        tm.DocketNo,  
        SUM(ISNULL(tm.ClaimedValue, 0)) AS TotalClaimValue,  
        COUNT(*) AS TotalClaimCount,  
        SUM(CASE WHEN tm.StatusId IN (1, 3, 4) THEN 1 ELSE 0 END) AS OpenClaimCount,  
        SUM(CASE WHEN tm.ComplaintTypeId = 1 THEN ISNULL(tm.ClaimedValue, 0) ELSE 0 END) AS DamageClaimValue,  
        SUM(CASE WHEN tm.ComplaintTypeId = 5 THEN ISNULL(tm.ClaimedValue, 0) ELSE 0 END) AS DelayClaimValue  
    FROM fct_crm_tickets tm WITH (NOLOCK)  
    GROUP BY tm.DocketNo  
),  
  
/* =========================================================================================
   PHASE 3: BASE AIR SHIPMENT ENGINE
   ========================================================================================= */  
Base_Air_Shipment AS (  
    SELECT  
        d.ID AS DocketID,  
        d.DocketNo,  
        d.DocketDate,  
        d.ServiceTypeId,  
        d.BillToId AS CustomerID,  
        cm.CustomerName,  
        cm.CustomerBranchID,  
  
        -- Geography
        d.BkPincode AS OriginPincode,  
        op.CityName AS OriginCity,  
        op.AirZone AS OriginZone,  
        op.AirportID AS OriginAirportID,  
        op.AirPickupBranchId AS OriginBranchId,  
  
        d.DlPincode AS DestPincode,  
        dp.CityName AS DestCity,  
        dp.AirZone AS DestZone,  
        dp.AirportID AS DestAirportID,  
        dp.AirDeliveryBranchId AS DestBranchId,  
  
        -- Metrics & Revenue
        d.ActualWeight AS ActualWeightKG,  
        d.ChargedWeight AS OriginalChargedWeightKG,  
        ISNULL(d.BasicFreight, 0) AS BasicFreight,  
        ISNULL(d.FuelSurcharge, 0) AS FuelSurcharge,  
        ISNULL(d.OdaCharge, 0) AS OdaCharge,  
        ISNULL(d.SubTotal, 0) AS ERP_RevenueExcGST,  
        ISNULL(d.DocketTotal, 0) AS ERP_RevenueIncGST,  
        (ISNULL(d.CGST, 0) + ISNULL(d.SGST, 0) + ISNULL(d.IGST, 0)) AS TotalGST,  
  
        d.EstDldate AS EDD,  
        d.DeliveryDate,  
        d.CurrentStatus  
  
    FROM fct_shipment d WITH(NOLOCK)  
    LEFT JOIN Customer_Final cm ON d.BillToId = cm.CustomerID  
    LEFT JOIN Air_Pincode_Final op ON LTRIM(RTRIM(CAST(d.BkPincode AS VARCHAR(20)))) = op.Pincode  
    LEFT JOIN Air_Pincode_Final dp ON LTRIM(RTRIM(CAST(d.DlPincode AS VARCHAR(20)))) = dp.Pincode  
    WHERE d.ServiceTypeId IN (4, 5, 10, 11) AND ISNULL(d.CancelDocket, 0) = 0  
),  
  
/* =========================================================================================
   PHASE 3B: AIRLINE LINEHAUL MAPPING & STRING AGGREGATION
   ========================================================================================= */  
THCAirline_Final AS (  
    SELECT  
        DocketNo,  
        STRING_AGG(CAST(THCAirlineName AS VARCHAR(MAX)), ', ') AS THCAirlineName,  
        STRING_AGG(CAST(ISNULL(THCFlightNo, '0') AS VARCHAR(MAX)), ', ') AS THCFlightNo,  
        MAX(THCFlightDate) AS THCFlightDate  
    FROM (  
        SELECT DISTINCT  
            pmd.DocketNo,  
            CASE  
                WHEN LOWER(t.AirAirlinesName) LIKE '%airindia%' THEN 'Air India'  
                WHEN LOWER(t.AirAirlinesName) LIKE '%indigo%' THEN 'IndiGo'  
                WHEN LOWER(t.AirAirlinesName) LIKE '%spicejet%' THEN 'SpiceJet'  
                ELSE 'Other Carrier'  
            END AS THCAirlineName,  
            NULLIF(LTRIM(RTRIM(t.AirFlightNo)), '') AS THCFlightNo,  
            CAST(t.AirDepartureDateTime AS DATE) AS THCFlightDate  
        FROM fct_trip_header t WITH (NOLOCK)  
        INNER JOIN fct_manifest_header pmh WITH (NOLOCK) ON pmh.THCID = t.ThcID  
        INNER JOIN fct_manifest_details pmd WITH (NOLOCK) ON pmd.ManifestId = pmh.Id  
        WHERE t.ServiceTypeId IN (4,5,10,11,12) AND ISNULL(pmh.TotalBag, 0) = 0  
    ) x  
    GROUP BY DocketNo  
),  
  
/* =========================================================================================
   PHASE 4: SLA & TAT ENGINE
   ========================================================================================= */  
SLA_Engine AS (  
    SELECT  
        bd.DocketNo,  
        CASE WHEN bd.EDD IS NULL OR bd.DocketDate IS NULL THEN NULL ELSE DATEDIFF(DAY, bd.DocketDate, bd.EDD) END AS NormalTATDays,  
        
        edd_calc.FinalEDD,  
  
        CASE  
            WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate <= edd_calc.FinalEDD THEN 'On-Time'  
            WHEN bd.DeliveryDate IS NOT NULL AND bd.DeliveryDate > edd_calc.FinalEDD THEN 'SLA Breach'  
            WHEN bd.DeliveryDate IS NULL AND dl.AttemptDate IS NOT NULL AND dl.AttemptDate > edd_calc.FinalEDD THEN 'SLA Breach'  
            WHEN bd.DeliveryDate IS NULL AND GETDATE() > edd_calc.FinalEDD THEN 'SLA Breach'  
            ELSE 'In-Transit'  
        END AS SLAStatus  
  
    FROM Base_Air_Shipment bd  
    LEFT JOIN DRS_Latest dl ON bd.DocketNo = dl.DocketNo  
    CROSS APPLY (  
        SELECT DATEADD(DAY, CASE WHEN dl.UndlyReasonId IN (13, 14, 23) THEN 1 ELSE 0 END, bd.EDD) AS FinalEDD  
    ) edd_calc  
),  
  
/* =========================================================================================
   PHASE 5: AIR HUB INDIRECT EXPENSES (PETTY CASH)
   ========================================================================================= */  
AIR_PetiCash_Final AS (  
    SELECT  
        'AIR_PETI_CASH' AS RecordType,  
        CAST(NULL AS VARCHAR(50)) AS DocketNo,  
        CAST(NULL AS DATETIME) AS DocketDate,  
        v.VoucherBranchId AS OriginBranchId,  
        CAST(0 AS DECIMAL(18,2)) AS ERP_RevenueExcGST,  
        CAST(0 AS DECIMAL(18,2)) AS ERP_RevenueIncGST,  
        CAST(NULL AS VARCHAR(100)) AS SLAStatus,  
        SUM(ISNULL(v.ApprovedAmount, 0)) AS PetiCash  
    FROM fct_voucher v WITH (NOLOCK)  
    INNER JOIN dim_account_heads ah WITH (NOLOCK) ON v.AccountCode = ah.AccountID  
    WHERE ah.GroupCode = 'INDIRECT EXPENSE'  
      AND v.VoucherBranchId IN (101, 102, 103, 104) -- Filtered to dedicated Air Hub IDs  
    GROUP BY v.VoucherID, v.VoucherBranchId, v.VoucherDate  
)  
  
/* =========================================================================================
   PHASE 6: FINAL ASSEMBLY (UNION DOCKETS AND EXPENSES)
   ========================================================================================= */  
SELECT  
    'AIR_DOCKET' AS RecordType,  
    bd.DocketNo,  
    bd.DocketDate,  
    bd.OriginBranchId,  
    bd.ERP_RevenueExcGST,  
    bd.ERP_RevenueIncGST,  
    sla.SLAStatus,  
    CAST(0 AS DECIMAL(18,2)) AS PetiCash  
FROM Base_Air_Shipment bd  
LEFT JOIN SLA_Engine sla ON bd.DocketNo = sla.DocketNo  
LEFT JOIN THCAirline_Final thcaf ON bd.DocketNo = thcaf.DocketNo  

UNION ALL  
  
SELECT * FROM AIR_PetiCash_Final;

END;
GO
