//helpers
function findObjectByKey(array, key, value) {
  for (var i = 0; i < array.length; i++) {
    if (array[i][key] === value) {
      return array[i];
    }
  }
  return null;
}
function findIndexByKey(array, key, value) {
  for (var i = 0; i < array.length; i++) {
    if (array[i][key] === value) {
      return i;
    }
  }
  return null;
}

class LiveMap {

    constructor(_config, _car_data, _map_data) { // Correctly accepts all three data pieces
      this.config = {
        parentElement: _config.parentElement,
        containerWidth: _config.containerWidth || 700,
        containerHeight: _config.containerHeight || 700,
        margin: { top: 25, bottom: 25, right: 25, left: 25}
      }
      this.map_data = _map_data;
      this.racer_data = _car_data; // Static racer metadata stored
      this.rt_data = []; // realtime data
      // Call a class function
      this.initVis();
    }
  
    initVis() {
      let vis = this;
      vis.startTime = Date.now();
      vis.splitTime = vis.startTime;
      vis.width = vis.config.containerWidth - vis.config.margin.left - vis.config.margin.right;
      vis.height = vis.config.containerHeight - vis.config.margin.top - vis.config.margin.bottom;
  
      // Setup Socket for local TCP data serving
      var socket = io.connect('http://' + location.hostname + ':' + location.port);
      socket.on( 'connect', function() {
        console.log("Socket connected!")    
      });
       
      socket.on('raceData', function( data ) {
        if (data == null){return}
        let size = Object.keys(data).length; 
        if(size > 0){
          vis.rt_data = data.realtime_data;
          vis.updateVis(); // No need to pass racer_data as it's static
        }else{
          console.log("Data Size 0");
        }
      });
      vis.all_elements = [];

      /// 1. Calculate the actual bounds of the track
      const xExtent = d3.extent(vis.map_data, d => d.midX);
      const yExtent = d3.extent(vis.map_data, d => d.midY);

      const xRange = xExtent[1] - xExtent[0];
      const yRange = yExtent[1] - yExtent[0];

      // 2. Determine the maximum dimension to maintain aspect ratio
      const maxRange = Math.max(xRange, yRange);

      // 3. Define a padding ratio for better aesthetics (e.g., 10%)
      const paddingRatio = 1.1; 
      const paddedMaxRange = maxRange * paddingRatio;

      // 4. Center the domain
      const xCenter = (xExtent[0] + xExtent[1]) / 2;
      const yCenter = (yExtent[0] + yExtent[1]) / 2;

      const xMin = xCenter - paddedMaxRange / 2;
      const xMax = xCenter + paddedMaxRange / 2;

      const yMin = yCenter - paddedMaxRange / 2;
      const yMax = yCenter + paddedMaxRange / 2;

      // 5. Update Scales with the squared/centered domain
      vis.xScale = d3.scaleLinear()
          .domain([xMin, xMax])
          .range([0, vis.width]);

      vis.yScale = d3.scaleLinear()
          .domain([yMin, yMax])
          .range([vis.height, 0]); // Keep inverted for typical map coords
            
  
      // Define size of SVG drawing area
      vis.svg = d3.select(vis.config.parentElement)
          .attr('width', vis.config.containerWidth)
          .attr('height', vis.config.containerHeight);
  
      // Append group element that will contain our actual chart (see margin convention)
      vis.chart = vis.svg.append('g')
          .attr('transform', `translate(${vis.config.margin.left},${vis.config.margin.top})`);

      
      vis.xValue = d => d.midX;
      vis.yValue = d => d.midY;
      vis.width = d => d.width;
      vis.line = d3.line() // Sets up Line for track path
          .x(d => vis.xScale(vis.xValue(d)))
          .y(d => vis.yScale(vis.yValue(d)));
     
      // inner path outline
      vis.chart.append('path')
      .attr('class', 'chart-line')
      .attr('d',vis.line(vis.map_data))
      .attr("fill", "none")

      vis.updateVis();
    }
  
  
    //We will add live Cars and live data 
    updateVis() { 
      let vis = this;
      const TRANSITION_DURATION = 75; // Fixed duration for smooth, snappy updates
      
      let rt_racers = vis.rt_data; // Realtime Data
      if (rt_racers == null){ rt_racers = []} 
  
      // --- 1. Secondary Marker (Thin Ring) ---
      vis.racerMarkerS = vis.chart.selectAll(".racerMarkerS")
      .data(rt_racers, d => d.id) // Use d.id as the key for the join
      
      // ENTER
      vis.racerMarkerS.enter()
      .append('circle')
      .attr("class","racerMarkerS")
      .attr("cx", d => vis.xScale(d.locX))
      .attr('cy', d => vis.yScale(d.locY))
      .attr("opacity",0)
      .attr("r", 20)
      .attr("fill", d => (d['secondary_color'].charAt(0) === '#') ? d['secondary_color'] : "#" + d['secondary_color'])
      .attr('stroke', d => (d['tertiary_color'].charAt(0) === '#') ? d['tertiary_color'] : "#" + d['tertiary_color'])
      .attr("stroke-width", 2)
      .transition()
      .attr("opacity", 0.90)
      .duration(100)

      // UPDATE
      vis.racerMarkerS.transition()
      .attr("cx", d => vis.xScale(d.locX))
      .attr('cy', d => vis.yScale(d.locY))
      .attr("opacity", 0.90)
      .attr("r", 20)
      .ease(d3.easeLinear)
      .duration(TRANSITION_DURATION)

      // EXIT
      vis.racerMarkerS.exit()
      .transition()
      .attr("opacity", 0)
      .attr("r", 0) 
      .duration(750) // FIXED: Now a number, not a string
      .remove()

      
      // --- 2. Primary Marker (Core Dot) ---
      vis.racerMarker = vis.chart.selectAll(".racerMarker")
      .data(rt_racers, d => d.id) // Use d.id as the key for the join

      // ENTER
      vis.racerMarker.enter()
      .append('circle')
      .attr("class","racerMarker")
      .attr("cx", d => vis.xScale(d.locX))
      .attr('cy', d => vis.yScale(d.locY))
      .attr("opacity",0)
      .attr("r", 13)
      .attr("fill", d => (d['primary_color'].charAt(0) === '#') ? d['primary_color'] : "#" + d['primary_color'])
      .attr('stroke', "none")
      .transition()
      .attr("opacity", 1)
      .duration(100)

      // UPDATE
      vis.racerMarker.transition()
      .attr("cx", d => vis.xScale(d.locX))
      .attr('cy', d => vis.yScale(d.locY))
      .attr("r", 13)
      .attr("opacity", 1)
      .ease(d3.easeLinear)
      .duration(TRANSITION_DURATION)

      // EXIT
      vis.racerMarker.exit()
      .transition()
      .attr("opacity",0)
      .attr("r", 0)
      .duration(750)
      .remove()


      vis.renderVis();
    }
  
    /**
     * This function contains the D3 code for binding data to visual elements
     * Important: renderVis() is intended to be called only once
     * Will also setup interactions?
     */
    renderVis() {
      let vis = this;
      // racer usernames (to be implemented later)
      // racer usernames (appear when hovered, stay when clicked (toggle))
      // what other things can i add for an interactive map? speed? tire fuel health? lap times?
          
    }
  
}