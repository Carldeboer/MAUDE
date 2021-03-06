## ----setup, include=FALSE-----------------------------------------------------
knitr::opts_chunk$set(echo = TRUE)

## ----load libraries, results="hide", message = FALSE, warning=FALSE-----------
library("ggplot2")
library(reshape)
library(cowplot)
library(MAUDE)
library(openxlsx)
library(edgeR)
library(DESeq2)

## ----set seed-----------------------------------------------------------------
set.seed(35263377)

## ----Load and parse CD69 data-------------------------------------------------
#a mapping to unify bin names from Simeonov data
binmapBack = list("baseline" = "baseline", "low"="low", "medium"="medium","high"="high","back_" = "NS",
                  "baseline_" = "baseline", "low_"="low", "medium_"="medium", "high_"="high", 
                  "A"="baseline", "B"="low", "E" = "medium", "F"="high")

#this comes from manually reconstructing the CD69 density curve from extended data figure 1a (Simeonov et al)
binBoundsCD69 = data.frame(Bin = c("A","F","B","E"), 
                           fraction = c(0.65747100, 0.02792824, 0.25146688, 0.06313389), 
                           stringsAsFactors = FALSE) 
fractionalBinBounds = makeBinModel(binBoundsCD69[c("Bin","fraction")])
fractionalBinBounds = rbind(fractionalBinBounds, fractionalBinBounds)
fractionalBinBounds$screen = c(rep("1",6),rep("2",6));
#only keep bins A,B,E,F
fractionalBinBounds = fractionalBinBounds[fractionalBinBounds$Bin %in% c("A","B","E","F"),]
fractionalBinBounds$Bin = unlist(binmapBack[fractionalBinBounds$Bin]);

#load data
cd69OriginalResults = read.xlsx('https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5675716/bin/NIHMS913084-supplement-supplementary_table_1.xlsx')
cd69OriginalResults$NT = grepl("negative_control", cd69OriginalResults$gRNA_systematic_name)
cd69OriginalResults$pos = cd69OriginalResults$PAM_3primeEnd_coord;
cd69OriginalResults = unique(cd69OriginalResults)
cd69CountData = melt(cd69OriginalResults, id.vars = c("pos","NT","gRNA_systematic_name"))
cd69CountData = cd69CountData[grepl(".count$",cd69CountData$variable),]
cd69CountData$theirBin = gsub("CD69(.*)([12]).count","\\1",cd69CountData$variable)
cd69CountData$screen = gsub("CD69(.*)([12]).count","\\2",cd69CountData$variable)
cd69CountData$reads= as.numeric(cd69CountData$value); cd69CountData$value=NULL;
# convert their bin to one that is consistent
cd69CountData$Bin = unlist(binmapBack[cd69CountData$theirBin]); 
binReadMat = data.frame(cast(cd69CountData[!is.na(cd69CountData$pos) | cd69CountData$NT,], pos+gRNA_systematic_name+NT+screen ~ Bin, value="reads"))

## ----calc logFC---------------------------------------------------------------
#confirm how to calc log2FC:
cd69OriginalResults$l2fc.vsbg1 = log2((1+ cd69OriginalResults$CD69high_1.count.norm)/(1+cd69OriginalResults$CD69back_1.count.norm))
cd69OriginalResults$l2fc.vsbg2 = log2((1+ cd69OriginalResults$CD69high_2.count.norm)/(1+cd69OriginalResults$CD69back_2.count.norm))
cd69OriginalResults$l2fc.hilo1 = log2((1+ cd69OriginalResults$CD69high_1.count.norm)/(1+cd69OriginalResults$CD69baseline_1.count.norm))
cd69OriginalResults$l2fc.hilo2 = log2((1+ cd69OriginalResults$CD69high_2.count.norm)/(1+cd69OriginalResults$CD69baseline_2.count.norm))
#confirm that how we just calculated log2 fc is the same as originally calculated
p=ggplot(cd69OriginalResults, aes(x=high2.l2fc,y= l2fc.vsbg2)) + geom_point(); print(p)

## ----run methods, results="hide", message = FALSE, warning=FALSE--------------
#edgeR
x <- unique(cd69OriginalResults[c("gRNA_systematic_name","CD69baseline_1.count","CD69baseline_2.count", 
                                  "CD69high_1.count", "CD69high2.count")])
row.names(x) = x$gRNA_systematic_name; x$gRNA_systematic_name=NULL;
x=as.matrix(x)
group <- factor(c(1,1,2,2))
y <- DGEList(counts=x,group=group)
y <- calcNormFactors(y)
design <- model.matrix(~group)
y <- estimateDisp(y,design)
#To perform likelihood ratio tests:
fit <- glmFit(y,design)
lrt <- glmLRT(fit,coef=2)
edgeRGuideLevel = topTags(lrt, n=nrow(x))@.Data[[1]]
edgeRGuideLevel$gRNA_systematic_name = row.names(edgeRGuideLevel);
edgeRGuideLevel$metric = edgeRGuideLevel$logFC;
edgeRGuideLevel$significance = -log(edgeRGuideLevel$PValue);
edgeRGuideLevel$method="edgeR";

#DESeq2
deseqGroups = data.frame(bin=factor(c(1,1,2,2)));
row.names(deseqGroups) = c("CD69baseline_1.count","CD69baseline_2.count", 
                           "CD69high_1.count", "CD69high2.count");
dds <- DESeqDataSetFromMatrix(countData = x,colData = deseqGroups, design= ~ bin)
dds <- DESeq(dds)
res <- results(dds, name=resultsNames(dds)[2])

deseqGuideLevel = as.data.frame(res@listData)
deseqGuideLevel$gRNA_systematic_name =res@rownames;
deseqGuideLevel$metric = deseqGuideLevel$log2FoldChange;
deseqGuideLevel$significance = -log(deseqGuideLevel$pvalue);
deseqGuideLevel$method="DESeq2";

#MAUDE
guideLevelStatsCD69 = findGuideHitsAllScreens(unique(binReadMat["screen"]), binReadMat, fractionalBinBounds, sortBins = c("baseline","high","low","medium"), unsortedBin = "NS")
guideLevelStatsCD69$chr="chr12"
guideLevelStatsCastCD69 = cast(guideLevelStatsCD69, gRNA_systematic_name + pos+NT ~ screen, value="Z")
names(guideLevelStatsCastCD69)[ncol(guideLevelStatsCastCD69)-1:0]=c("s1","s2")
guideLevelStatsCastCD69$significance = apply(guideLevelStatsCastCD69[c("s1","s2")],1, combineZStouffer)
guideLevelStatsCastCD69$metric=apply(guideLevelStatsCastCD69[c("s1","s2")],1, mean)
guideLevelStatsCastCD69$method = "MAUDE"

#Two log fold change methods
cd69OriginalResultsHiLow = cd69OriginalResults[c("gRNA_systematic_name","l2fc.hilo1","l2fc.hilo2")]
cd69OriginalResultsVsBG = cd69OriginalResults[c("gRNA_systematic_name","l2fc.vsbg1","l2fc.vsbg2")]
cd69OriginalResultsHiLow$significance = apply(cd69OriginalResultsHiLow[2:3], 1, FUN = mean)
cd69OriginalResultsHiLow$metric = apply(cd69OriginalResultsHiLow[2:3], 1, FUN = mean)
cd69OriginalResultsVsBG$significance = apply(cd69OriginalResultsVsBG[2:3], 1, FUN = mean)
cd69OriginalResultsVsBG$metric = apply(cd69OriginalResultsVsBG[2:3], 1, FUN = mean)
cd69OriginalResultsHiLow$method="logHivsLow"
cd69OriginalResultsVsBG$method="logVsUnsorted"

## ----compile results----------------------------------------------------------
# predictions
allResults = rbind(cd69OriginalResultsVsBG[c("method","gRNA_systematic_name","significance","metric")],
                   cd69OriginalResultsHiLow[c("method","gRNA_systematic_name","significance","metric")],
                   deseqGuideLevel[c("method","gRNA_systematic_name","significance","metric")], 
                   edgeRGuideLevel[c("method","gRNA_systematic_name","significance","metric")],
                   guideLevelStatsCastCD69[c("method","gRNA_systematic_name","significance","metric")]) 


allResults = merge(allResults, cd69OriginalResults[c("gRNA_systematic_name","NT","pos")],
                   by="gRNA_systematic_name")
allResults = allResults[!is.na(allResults$pos) | allResults$NT,]
allResults$promoter  = allResults$pos <= 9913996 & allResults$pos >= 9912997
allResults$gID = allResults$gRNA_systematic_name; allResults$gRNA_systematic_name=NULL;
allResults$locus ="CD69"
allResults$type ="CRISPRa"
allResults$celltype ="Jurkat"

## ----input and parse TNFAIP3 data---------------------------------------------

##read in TNFAIP3 data
binFractionsA20 = read.table(textConnection(readLines(gzcon(url("https://ftp.ncbi.nlm.nih.gov/geo/series/GSE136nnn/GSE136693/suppl/GSE136693_20190828_CRISPR_FF_bin_fractions.txt.gz")))), 
                             sep="\t", stringsAsFactors = FALSE, header = TRUE)
CRISPRaCountsA20 = read.table(textConnection(readLines(gzcon(url("https://ftp.ncbi.nlm.nih.gov/geo/series/GSE136nnn/GSE136693/suppl/GSE136693_20190828_CRISPRa_FF_countMatrix.txt.gz")))), 
                              sep="\t", stringsAsFactors = FALSE, header = TRUE)
CRISPRiCountsA20 = read.table(textConnection(readLines(gzcon(url("https://ftp.ncbi.nlm.nih.gov/geo/series/GSE136nnn/GSE136693/suppl/GSE136693_20190828_CRISPRi_FF_countMatrix.txt.gz")))), 
                              sep="\t", stringsAsFactors = FALSE, header = TRUE)
crispraGuides = read.table(textConnection(readLines(gzcon(url("https://ftp.ncbi.nlm.nih.gov/geo/series/GSE136nnn/GSE136693/suppl/GSE136693_20180205_selected_CRISPRa_guides_seq.txt.gz")))), 
                           sep="\t", stringsAsFactors = FALSE, header = TRUE)
crispraGuides$seq = gsub("(.*)(.{3})","\\1",crispraGuides$seq.w.PAM)
crispraGuides$pos = round((as.numeric(gsub("([0-9]+):([0-9]+)-([0-9]+):([+-])","\\2",
                                           crispraGuides$guideID))+
                             as.numeric(gsub("([0-9]+):([0-9]+)-([0-9]+):([+-])","\\3",
                                             crispraGuides$guideID)))/2)

CRISPRaCountsA20 = merge(CRISPRaCountsA20, unique(crispraGuides[c("seq","pos")]), by=c("seq"), all.x=TRUE)

CRISPRiCountsA20$pos = round((as.numeric(gsub("([0-9]+):([0-9]+)-([0-9]+):([+-])","\\2",
                                              CRISPRiCountsA20$gID))+
                                as.numeric(gsub("([0-9]+):([0-9]+)-([0-9]+):([+-])","\\3",
                                              CRISPRiCountsA20$gID)))/2)

binFractionsA20$expt = paste(binFractionsA20$celltype, binFractionsA20$CRISPRType,sep="_")

#merge CRISPRi and CRISPRa
A20CountData = melt(CRISPRaCountsA20, id.vars=c("seq","elementClass","element","NT","gID","pos"))
A20CountData$CRISPRType="CRISPRa";
A20CountData2 = melt(CRISPRiCountsA20, id.vars=c("seq","elementClass","element","NT","gID","pos"))
A20CountData2$CRISPRType="CRISPRi";
A20CountData = rbind(A20CountData, A20CountData2)
rm('A20CountData2');
A20CountData$count = A20CountData$value; A20CountData$value=NULL;
A20CountData$sample = A20CountData$variable; A20CountData$variable=NULL;
A20CountData$bin = gsub("(.*)_(.*)_(.*)", "\\3", A20CountData$sample);
A20CountData$screen = gsub("(.*)_(.*)_(.*)", "\\2", A20CountData$sample);
A20CountData$celltype = gsub("(.*)_(.*)_(.*)", "\\1", A20CountData$sample);
A20CountData$expt = paste(A20CountData$celltype, A20CountData$CRISPRType,sep="_")

## ----start evaluation and run on TNFAIP3, results="hide", message = FALSE, warning=FALSE----
#combine CD69 metrics 
# Pearson's r between replicates ## metricsBoth will contain all our evaluation metrics
metricsBoth = 
  data.frame(method=c("MAUDE","logHivsLow","logVsUnsorted"), metric="r",which="replicate_correl",
             value=c(cor(guideLevelStatsCastCD69$s1[!guideLevelStatsCastCD69$NT],
                         guideLevelStatsCastCD69$s2[!guideLevelStatsCastCD69$NT]), 
                     cor(cd69OriginalResults$l2fc.hilo1[!cd69OriginalResults$NT],
                         cd69OriginalResults$l2fc.hilo2[!cd69OriginalResults$NT]),
                     cor(cd69OriginalResults$l2fc.vsbg1[!cd69OriginalResults$NT],
                         cd69OriginalResults$l2fc.vsbg2[!cd69OriginalResults$NT])),
             sig=c(cor.test(guideLevelStatsCastCD69$s1[!guideLevelStatsCastCD69$NT],
                            guideLevelStatsCastCD69$s2[!guideLevelStatsCastCD69$NT])$p.value, 
                   cor.test(cd69OriginalResults$l2fc.hilo1[!cd69OriginalResults$NT],
                            cd69OriginalResults$l2fc.hilo2[!cd69OriginalResults$NT])$p.value,
                   cor.test(cd69OriginalResults$l2fc.vsbg1[!cd69OriginalResults$NT],
                            cd69OriginalResults$l2fc.vsbg2[!cd69OriginalResults$NT])$p.value),
             locus="CD69",type="CRISPRa",celltype="Jurkat",stringsAsFactors = FALSE)

allResultsBoth = allResults; #combined results (significance, effect sizes) for CD69 and A20 screens
for (e in unique(binFractionsA20$expt)){
  curCelltype = gsub("(.*)_(.*)", "\\1", e);
  curtype = gsub("(.*)_(.*)", "\\2", e);
  curA20CountData = unique(A20CountData[A20CountData$expt==e,
                                        c("seq","pos", "NT","gID","count","screen","bin")])
  curA20CountDataTotals = cast(curA20CountData, screen +bin~ ., fun.aggregate = sum, value="count")
  names(curA20CountDataTotals)[3] = "total";
  curA20CountData = merge(curA20CountData, curA20CountDataTotals, by=c("screen","bin"))
  curA20CountData$CPM = curA20CountData$count/curA20CountData$total * 1E6;
  curCPMMat = cast(curA20CountData, seq + NT + gID + screen + pos ~ bin, value="CPM")
  curCPMMat$l2fc_hilo = log2((1+curCPMMat$F)/(1+curCPMMat$A))
  if(curtype=="CRISRPi"){
    curCPMMat$l2fc_vsbg = log2((1+curCPMMat$NS)/(1+curCPMMat$A))
  }else{ #CRISPRa
    curCPMMat$l2fc_vsbg = log2((1+curCPMMat$F)/(1+curCPMMat$NS))
  }
  curBins = as.data.frame(melt(binFractionsA20[binFractionsA20$expt==e,], 
                               id.vars = c("celltype","screen","CRISPRType","expt")))
  names(curBins)[ncol(curBins) - (1:0)] = c("Bin","fraction")
  curBins2 = data.frame();
  for (s in unique(curBins$screen)){
    curBins3 = makeBinModel(curBins[curBins$screen==s,c("Bin","fraction")])
    curBins3$screen = s;
    curBins2 = rbind(curBins2, curBins3)
  }
  curBins2$Bin = as.character(curBins2$Bin);
  curCountMat = cast(curA20CountData, seq + NT + gID +pos + screen ~ bin, value="count")
  guideLevelStats = findGuideHitsAllScreens(experiments = unique(curCountMat["screen"]), 
                                            countDataFrame = curCountMat, binStats = curBins2, 
                                            sortBins = c("A","B","C","D","E","F"), unsortedBin = "NS", 
                                            negativeControl="NT")
  
  guideLevelStatsCast = cast(guideLevelStats, gID + pos+NT ~ screen, value="Z")
  #names(guideLevelStatsCast)[4:ncol(guideLevelStatsCast)]=sprintf("s%i", 1:(ncol(guideLevelStatsCast)-3))
  
  maudeZs = guideLevelStatsCast;
  
  guideLevelStatsCast$significance = apply(maudeZs[unique(curA20CountData$screen)],1, combineZStouffer)
  guideLevelStatsCast$metric=apply(maudeZs[unique(curA20CountData$screen)],1, mean)
  guideLevelStatsCast$method = "MAUDE"
  
  ### EdgeR
  library(edgeR)
  x= cast(unique(curA20CountData[curA20CountData$bin %in% c("A","F"), c("bin","gID","screen","count")]), gID ~ screen + bin, value="count")
  row.names(x) = x$gID; x$gID=NULL;
  x=as.matrix(x)
  group = grepl("_F",colnames(x))+1
  group <- factor(group)
  y <- DGEList(counts=x,group=group)
  y <- calcNormFactors(y)
  design <- model.matrix(~group)
  y <- estimateDisp(y,design)
  #To perform likelihood ratio tests:
  fit <- glmFit(y,design)
  lrt <- glmLRT(fit,coef=2)
  edgeRGuideLevel = topTags(lrt, n=nrow(x))@.Data[[1]]
  
  edgeRGuideLevel$gID = row.names(edgeRGuideLevel);
  edgeRGuideLevel$metric = edgeRGuideLevel$logFC;
  edgeRGuideLevel$significance = -log(edgeRGuideLevel$PValue);
  edgeRGuideLevel$method="edgeR";
  
  ### DEseq
  library(DESeq2)
  deseqGroups = data.frame(bin=group);
  row.names(deseqGroups) = colnames(x);
  dds <- DESeqDataSetFromMatrix(countData = x,colData = deseqGroups, design= ~ bin)
  dds <- DESeq(dds)
  #resultsNames(dds) # lists the coefficients
  res <- results(dds, name=resultsNames(dds)[2])
  stopifnot(resultsNames(dds)[1]=="Intercept")
  deseqGuideLevel = as.data.frame(res@listData)
  deseqGuideLevel$gID =res@rownames;
  deseqGuideLevel$metric = deseqGuideLevel$log2FoldChange;
  deseqGuideLevel$significance = -log(deseqGuideLevel$pvalue);
  deseqGuideLevel$method="DESeq2";
  
  curLRHiLow = cast(unique(curCPMMat[c("gID","NT","screen","l2fc_hilo")]), gID + NT ~ screen, value="l2fc_hilo")
  curLRVsBG = cast(unique(curCPMMat[c("gID","NT","screen","l2fc_vsbg")]), gID + NT ~ screen, value="l2fc_vsbg")
  numSamples = ncol(curLRHiLow)-2;
  sampleNames = unique(curCPMMat$screen)
  
  curLRVsBG$significance = apply(curLRVsBG[3:(numSamples+2)], MARGIN = 1, FUN = mean);
  curLRVsBG$metric = apply(curLRVsBG[3:(numSamples+2)], MARGIN = 1, FUN = mean);
  curLRVsBG$method="logVsUnsorted"
  curLRHiLow$significance = apply(curLRHiLow[3:(numSamples+2)], MARGIN = 1, FUN = mean);
  curLRHiLow$metric = apply(curLRHiLow[3:(numSamples+2)], MARGIN = 1, FUN = mean);
  curLRHiLow$method="logHivsLow"
  
  #compile results for A20
  curResults = rbind(unique(curLRHiLow[c("method","gID","significance","metric")]),
                     unique(curLRVsBG[c("method","gID","significance","metric")]),
                     deseqGuideLevel[c("method","gID","significance","metric")], 
                     edgeRGuideLevel[c("method","gID","significance","metric")],
                     unique(guideLevelStatsCast[c("method","gID","significance","metric")]))
  
  curResults = merge(curResults, unique(curCPMMat[c("gID","NT","pos")]), by="gID")
  curResults = curResults[!is.na(curResults$pos) | curResults$NT,]
  curResults$promoter  = grepl("TNFAIP3", curResults$gID) | 
    (curResults$pos <= 138189439 & curResults$pos >= 138187040) # chr6:138188077-138188379;138187040
  
  #append the current results to all
  curResults$locus ="TNFAIP3"
  curResults$type =curtype
  curResults$celltype =curCelltype
  allResultsBoth = rbind(allResultsBoth, curResults);
  
  # (1) similarity between the effect sizes estimated per replicate, 
  corLRHiLow = cor(curLRHiLow[!curLRHiLow$NT, 3:(3+numSamples-1)])
  corLRVsBG = cor(curLRVsBG[!curLRVsBG$NT, 3:(3+numSamples-1)])
  maudeZCors = cor(maudeZs[!maudeZs$NT, 4:ncol(maudeZs)])
  
  maudeCorP=1
  maudeCorR=-1
  corLRHiLowP=1
  corLRHiLowR=-1
  corLRVsBGP=1;
  corLRVsBGR=-1
  #select the best inter-replicate correlation for each of the three approaches for which this is possible
  for(i in 1:(length(sampleNames)-1)){ 
    for(j in (i+1):length(sampleNames)){ 
      curR = cor(maudeZs[!maudeZs$NT, sampleNames[i]], maudeZs[!maudeZs$NT, sampleNames[j]])
      curP = cor.test(maudeZs[!maudeZs$NT, sampleNames[i]], maudeZs[!maudeZs$NT, sampleNames[j]])$p.value
      if (maudeCorR < curR){
        maudeCorR = curR;
        maudeCorP = curP;
      }
      curR = cor(curLRVsBG[!curLRVsBG$NT, sampleNames[i]], curLRVsBG[!curLRVsBG$NT, sampleNames[j]])
      curP = cor.test(curLRVsBG[!curLRVsBG$NT, sampleNames[i]], 
                      curLRVsBG[!curLRVsBG$NT, sampleNames[j]])$p.value
      if (corLRVsBGR < curR){
        corLRVsBGR = curR;
        corLRVsBGP = curP;
      }
      curR = cor(curLRHiLow[!curLRHiLow$NT, sampleNames[i]], curLRHiLow[!curLRHiLow$NT, sampleNames[j]])
      curP = cor.test(curLRHiLow[!curLRHiLow$NT, sampleNames[i]], 
                      curLRHiLow[!curLRHiLow$NT, sampleNames[j]])$p.value
      if (corLRHiLowR < curR){
        corLRHiLowR = curR;
        corLRHiLowP = curP;
      }
    }
  }
  metricsBoth = rbind(metricsBoth, 
                      data.frame(method=c("MAUDE","logHivsLow","logVsUnsorted"), 
                                 metric="r",which="replicate_correl",
                                 value=c(maudeCorR, corLRHiLowR, corLRVsBGR),
                                 sig=c(maudeCorP, corLRHiLowP, corLRVsBGP), 
                                 locus ="TNFAIP3", type =curtype, celltype =curCelltype, 
                                 stringsAsFactors = FALSE))
}

## ----some useful functions----------------------------------------------------
#Some useful functions
ranksumROC = function(x,y,na.rm=TRUE,...){
  if (na.rm){
    x=na.rm(x);
    y=na.rm(y);
  }
  curTest = wilcox.test(x,y,...);
  curTest$AUROC = (curTest$statistic/length(x))/length(y)
  return(curTest)
}
na.rm = function(x){ x[!is.na(x)]}

## ----evaluate methods part 2 and 3--------------------------------------------
# (1) similarity between the effect sizes estimated per replicate, 
# (above)
metricsBoth$significant= metricsBoth$sig < 0.01;

# Other evaluation metrics
allExpts = unique(allResultsBoth[c("celltype","locus","type")])
for (ei in 1:nrow(allExpts)){
  curCelltype = allExpts$celltype[ei]
  curtype = allExpts$type[ei];
  curLocus = allExpts$locus[ei];
  
  curResults = allResultsBoth[allResultsBoth$celltype==curCelltype & 
                                allResultsBoth$type==curtype & allResultsBoth$locus==curLocus,]
  for(m in unique(curResults$method)){
    curData = curResults[curResults$method==m & !curResults$NT,]
    
    # (2) similarity in effect size between adjacent guides
    curData = curData[order(curData$pos),]
    guideEffectDistances = 
      data.frame(method = m, random=FALSE, 
                 difference = abs(curData$metric[2:nrow(curData)] - curData$metric[1:(nrow(curData)-1)]), 
                 dist =abs(curData$pos[2:nrow(curData)] - curData$pos[1:(nrow(curData)-1)]), 
                 stringsAsFactors = FALSE)
    guideEffectDistances = guideEffectDistances[guideEffectDistances$dist < 100,]
    guideEffectDistances$dist=NULL;
    ### changed 10 in next line to 100 to make this more robust
    curData = curData[sample(nrow(curData), size = nrow(curData)*100, replace = TRUE),]
    guideEffectDistances = 
      rbind(guideEffectDistances,
            data.frame(method = m, random=TRUE,
                       difference = abs(curData$metric[2:nrow(curData)] - 
                                          curData$metric[1:(nrow(curData)-1)]), stringsAsFactors = FALSE));
    # random should have more different than adjacent
    curRS = ranksumROC(guideEffectDistances$difference[guideEffectDistances$method==m &
                                                         guideEffectDistances$random],
                       guideEffectDistances$difference[guideEffectDistances$method==m &
                                                         !guideEffectDistances$random]) 
    metricsBoth = rbind(metricsBoth, data.frame(method=m, metric="AUROC-0.5",
                                                which="adjacent_vs_random",value = curRS$AUROC-0.5,
                                                locus=curLocus,celltype=curCelltype, type=curtype,
                                                sig=curRS$p.value, significant = curRS$p.value < 0.01))
    
    # (3) ability to distinguish promoter-targeting guides from other guides. 
    if (curtype=="CRISPRi" & !(m %in% c("edgeR","DESeq2"))){ 
      # edgeR and DESeq2 are reversed for CRISPRi
      # non promoter should have higher effect than promoter (more -ve)
      curRS = ranksumROC(curResults$significance[curResults$method==m & !curResults$NT &
                                                   !curResults$promoter],
                         curResults$significance[curResults$method==m & !curResults$NT &
                                                   curResults$promoter]) 
    }else{
      # promoter should have larger effect than non-promoter
      curRS = ranksumROC(curResults$significance[curResults$method==m & !curResults$NT &
                                                   curResults$promoter],
                         curResults$significance[curResults$method==m & !curResults$NT &
                                                   !curResults$promoter]) 
    }
    metricsBoth = rbind(metricsBoth, data.frame(method=m, metric="AUROC-0.5", which="promoter_vs_T",
                                                value = curRS$AUROC-0.5, locus=curLocus, 
                                                celltype=curCelltype, type=curtype, sig=curRS$p.value,
                                                significant = curRS$p.value < 0.01))
  }
}

##compile all metrics; label the best in each test and whether any tests were significant (P<0.01)
metricsBoth2 = metricsBoth;
metricsBoth2$method = factor(as.character(metricsBoth2$method), 
                             levels = c("logVsUnsorted","logHivsLow","DESeq2","edgeR","MAUDE"))
metricsBoth2Best = cast(metricsBoth2, which + locus + type+celltype ~ ., value="value", 
                        fun.aggregate = max)
names(metricsBoth2Best)[ncol(metricsBoth2Best)] = "best"
metricsBoth2 = merge(metricsBoth2, metricsBoth2Best, by = c("which","locus","type","celltype"))
metricsBoth2AnySig = cast(metricsBoth2[colnames(metricsBoth2)!="value"], 
                          which + locus + type+celltype ~ ., value="significant", fun.aggregate = any)
names(metricsBoth2AnySig)[ncol(metricsBoth2AnySig)] = "anySig"
metricsBoth2 = merge(metricsBoth2, metricsBoth2AnySig, by = c("which","locus","type","celltype"))
metricsBoth2$isBest = metricsBoth2$value==metricsBoth2$best;
metricsBoth2$isBestNA = metricsBoth2$isBest;
metricsBoth2$isBestNA[!metricsBoth2$isBestNA]=NA;
metricsBoth2$pctOfMax = metricsBoth2$value/metricsBoth2$best * 100;

#fill in NAs for edgeR and DESeq2 which cannot have inter-replicate correlations
temp = metricsBoth2[metricsBoth2$metric=="r",]
temp = temp[1:2,];
temp$method = c("edgeR","DESeq2")
temp$value=NA; temp$isBest=NA; temp$significant=FALSE; temp$pctOfMax=NA; temp$isBestNA=NA;
metricsBoth2 = rbind(metricsBoth2, temp)

## ----make graph, fig.width=10, fig.height=6-----------------------------------
#make the final evaluation graph
p1 = ggplot(metricsBoth2[metricsBoth2$which=="adjacent_vs_random",], 
            aes(x=method, fill=value, y=paste(locus,type,celltype))) + geom_tile() +
  geom_text(data=metricsBoth2[metricsBoth2$which=="adjacent_vs_random" & metricsBoth2$anySig,],
            aes(label="*",colour=isBestNA),show.legend = FALSE) +theme_bw() +
  scale_fill_gradient2(high="red", low="blue", mid="black") + 
  theme(legend.position="top", axis.text.x = element_text(hjust=1, angle=45), 
        axis.title.y = element_blank())+scale_colour_manual(values = c("green"), na.value=NA) + 
  scale_y_discrete(expand=c(0,0))+scale_x_discrete(expand=c(0,0))+ggtitle("Adjacent vs\nrandom guides");
p2 = ggplot(metricsBoth2[metricsBoth2$which=="promoter_vs_T",], 
            aes(x=method, fill=value, y=paste(locus,type,celltype))) + geom_tile() +
  geom_text(data=metricsBoth2[metricsBoth2$which=="promoter_vs_T" & metricsBoth2$anySig,],
            aes(label="*",colour=isBestNA),show.legend = FALSE) +theme_bw() +
  scale_fill_gradient2(high="red", low="blue", mid="black") + 
  theme(legend.position="top", axis.text.x = element_text(hjust=1, angle=45), 
        axis.title.y = element_blank())+scale_colour_manual(values = c("green"), na.value=NA)+
  scale_y_discrete(expand=c(0,0))+scale_x_discrete(expand=c(0,0))+
  ggtitle("Promoter vs other\ntargeting guides");
p3 = ggplot(metricsBoth2[metricsBoth2$which=="replicate_correl",], 
            aes(x=method, fill=value, y=paste(locus,type,celltype))) + geom_tile() +
  geom_text(data=metricsBoth2[metricsBoth2$which=="replicate_correl" & metricsBoth2$anySig,],
            aes(label="*",colour=isBestNA),show.legend = FALSE) +theme_bw() +
  scale_fill_gradient2(high="red", low="blue", mid="black") + 
  theme(legend.position="top", axis.text.x = element_text(hjust=1, angle=45), 
        axis.title.y = element_blank())+scale_colour_manual(values = c("green"), na.value=NA)+
  scale_y_discrete(expand=c(0,0))+scale_x_discrete(expand=c(0,0))+ggtitle("Replicate\ncorrelations");
g= plot_grid(p1,p2,p3, align = 'h', nrow = 1); print(g)

## ----session info-------------------------------------------------------------
sessionInfo()

